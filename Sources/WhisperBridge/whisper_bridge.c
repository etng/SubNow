#include "whisper.h"
#include "include/whisper_bridge.h"
#include "ggml.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// SUBNOW_VERBOSE=1 时把 ggml/whisper 的 DEBUG 级日志也放出来（生产排障用）
static void snwh_log_cb(enum ggml_log_level level, const char * text, void * user_data) {
    (void) user_data;
    static const char * names[] = { "none", "debug", "info", "warn", "error" };
    const char * name = (level >= 0 && level <= 4) ? names[level] : "?";
    fprintf(stderr, "[ggml:%s] %s", name, text);
}

static void snwh_install_verbose_logging_if_requested(void) {
    static int installed = 0;
    if (installed) return;
    installed = 1;
    const char * v = getenv("SUBNOW_VERBOSE");
    if (v && v[0] == '1') {
        ggml_log_set(snwh_log_cb, NULL);
    }
}

struct snwh_context {
    struct whisper_context * wctx;
    char vad_model[4096];
    char language[32];
    snwh_progress_fn progress_fn; void * progress_ud;
    snwh_abort_fn abort_fn;       void * abort_ud;
    int abort_requested;
};

// ---- 回调 ----

static void bridge_progress_cb(struct whisper_context * ctx,
                               struct whisper_state * state,
                               int progress, void * user_data) {
    (void) ctx; (void) state;
    struct snwh_context * c = (struct snwh_context *) user_data;
    if (c && c->progress_fn) c->progress_fn(c->progress_ud, progress);
}

// ggml 约定：回调返回 true = 中止计算。
// 我们的桥约定（见 whisper_bridge.h）：abort_fn 返回 false = 中止。
static bool bridge_abort_cb(void * user_data) {
    struct snwh_context * c = (struct snwh_context *) user_data;
    if (c && c->abort_fn) {
        bool keep_going = c->abort_fn(c->abort_ud);
        if (!keep_going) c->abort_requested = 1;
        return !keep_going;
    }
    return false;  // 无回调：永不中止
}

// ---- 16kHz 单声道 PCM16 WAV 读取 ----
// 我们自己的提取步骤保证该格式；其余格式直接报错，避免静默错位。

static bool read_wav_16k_mono(const char * path, float ** out_samples, int * out_len, char * err, int err_len) {
    FILE * f = fopen(path, "rb");
    if (!f) { snprintf(err, err_len, "无法打开音频文件: %s", path); return false; }

    unsigned char hdr[12];
    if (fread(hdr, 1, 12, f) != 12 || memcmp(hdr, "RIFF", 4) != 0 || memcmp(hdr + 8, "WAVE", 4) != 0) {
        fclose(f); snprintf(err, err_len, "不是 WAV 文件: %s", path); return false;
    }

    int fmt = -1, channels = 0, rate = 0, bits = 0;
    long data_pos = -1; unsigned int data_size = 0;

    for (;;) {
        unsigned char chunk[8];
        if (fread(chunk, 1, 8, f) != 8) break;
        unsigned int sz = (unsigned int) chunk[4] | ((unsigned int) chunk[5] << 8)
                        | ((unsigned int) chunk[6] << 16) | ((unsigned int) chunk[7] << 24);
        if (memcmp(chunk, "fmt ", 4) == 0) {
            unsigned char fbuf[16];
            if (sz < 16 || fread(fbuf, 1, 16, f) != 16) break;
            fmt      = (int) fbuf[0] | ((int) fbuf[1] << 8);
            channels = (int) fbuf[2] | ((int) fbuf[3] << 8);
            rate     = (int) fbuf[4] | ((int) fbuf[5] << 8) | ((int) fbuf[6] << 16) | ((int) fbuf[7] << 24);
            bits     = (int) fbuf[14] | ((int) fbuf[15] << 8);
            if (sz > 16) fseek(f, sz - 16, SEEK_CUR);
        } else if (memcmp(chunk, "data", 4) == 0) {
            data_pos = ftell(f);
            data_size = sz;
            break;  // 读完头部即可，data 后面一般没有别的块
        } else {
            fseek(f, (long)((sz + 1) & ~1u), SEEK_CUR);  // 块按 2 字节对齐
        }
    }

    if (data_pos < 0 || fmt != 1 || channels != 1 || rate != 16000 || bits != 16) {
        fclose(f);
        snprintf(err, err_len, "音频格式不符（需 16kHz 单声道 PCM16，实际 fmt=%d ch=%d rate=%d bits=%d）",
                 fmt, channels, rate, bits);
        return false;
    }
    if (data_size == 0 || (data_size % 2) != 0) data_size &= ~1u;

    int n = (int)(data_size / 2);
    float * samples = (float *) malloc(sizeof(float) * (size_t)(n > 0 ? n : 1));
    if (!samples) { fclose(f); snprintf(err, err_len, "内存不足"); return false; }

    unsigned char buf[8192];
    int got = 0;
    while (got < n) {
        int want = n - got; if (want > (int)(sizeof(buf) / 2)) want = (int)(sizeof(buf) / 2);
        size_t r = fread(buf, 2, (size_t) want, f);
        if (r == 0) break;
        for (size_t i = 0; i < r; ++i) {
            short v = (short)((unsigned short) buf[i * 2] | ((unsigned short) buf[i * 2 + 1] << 8));
            samples[got + (int) i] = (float) v / 32768.0f;
        }
        got += (int) r;
    }
    fclose(f);

    if (got <= 0) { free(samples); snprintf(err, err_len, "音频为空"); return false; }
    *out_samples = samples;
    *out_len = got;
    return true;
}

// ---- 对外 API ----

snwh_context_t * snwh_load(const char * model_path, const char * vad_model_path,
                           char * err_buf, int err_len) {
    snwh_install_verbose_logging_if_requested();
    struct whisper_context_params cparams = whisper_context_default_params();
    // SUBNOW_NO_GPU=1 → 强制 CPU（对照排障用）
    const char * no_gpu = getenv("SUBNOW_NO_GPU");
    if (no_gpu && no_gpu[0] == '1') cparams.use_gpu = false;
    struct whisper_context * w = whisper_init_from_file_with_params(model_path, cparams);
    if (!w) {
        snprintf(err_buf, err_len, "模型加载失败: %s", model_path);
        return NULL;
    }
    struct snwh_context * c = (struct snwh_context *) calloc(1, sizeof(*c));
    if (!c) { whisper_free(w); snprintf(err_buf, err_len, "内存不足"); return NULL; }
    c->wctx = w;
    if (vad_model_path && vad_model_path[0]) {
        snprintf(c->vad_model, sizeof(c->vad_model), "%s", vad_model_path);
    }
    return c;
}

void snwh_free(snwh_context_t * ctx) {
    if (!ctx) return;
    whisper_free(ctx->wctx);
    free(ctx);
}

int snwh_run(snwh_context_t * ctx, const char * wav_path, const char * language,
             snwh_progress_fn progress_fn, void * progress_ud,
             snwh_abort_fn abort_fn, void * abort_ud,
             char * err_buf, int err_len) {
    if (!ctx || !wav_path) { snprintf(err_buf, err_len, "参数为空"); return -1; }

    float * samples = NULL;
    int n_samples = 0;
    if (!read_wav_16k_mono(wav_path, &samples, &n_samples, err_buf, err_len)) return -1;

    ctx->progress_fn = progress_fn; ctx->progress_ud = progress_ud;
    ctx->abort_fn    = abort_fn;    ctx->abort_ud    = abort_ud;
    ctx->abort_requested = 0;

    struct whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.print_progress   = false;
    p.print_special    = false;
    p.print_realtime   = false;
    p.print_timestamps = false;
    p.language         = (language && language[0] && strcmp(language, "auto") != 0) ? language : NULL;
    p.translate        = false;
    p.progress_callback          = bridge_progress_cb;
    p.progress_callback_user_data = ctx;
    p.abort_callback             = bridge_abort_cb;
    p.abort_callback_user_data   = ctx;
    if (ctx->vad_model[0]) {
        p.vad = true;
        p.vad_model_path = ctx->vad_model;
    }

    int rc = whisper_full(ctx->wctx, p, samples, n_samples);
    free(samples);

    if (ctx->abort_requested) {
        snprintf(err_buf, err_len, "转录被中止");
        return -2;
    }
    if (rc != 0) {
        snprintf(err_buf, err_len, "whisper_full 失败（rc=%d）", rc);
        return -1;
    }

    int lang_id = whisper_full_lang_id(ctx->wctx);
    if (lang_id >= 0) {
        const char * code = whisper_lang_str(lang_id);
        snprintf(ctx->language, sizeof(ctx->language), "%s", code ? code : "auto");
    } else {
        snprintf(ctx->language, sizeof(ctx->language), "auto");
    }
    return 0;
}

int snwh_segment_count(snwh_context_t * ctx) {
    return ctx ? whisper_full_n_segments(ctx->wctx) : 0;
}

int64_t snwh_segment_t0(snwh_context_t * ctx, int i) {
    return ctx ? whisper_full_get_segment_t0(ctx->wctx, i) : 0;
}

int64_t snwh_segment_t1(snwh_context_t * ctx, int i) {
    return ctx ? whisper_full_get_segment_t1(ctx->wctx, i) : 0;
}

const char * snwh_segment_text(snwh_context_t * ctx, int i) {
    return ctx ? whisper_full_get_segment_text(ctx->wctx, i) : "";
}

const char * snwh_detected_language(snwh_context_t * ctx) {
    return ctx ? ctx->language : "auto";
}
