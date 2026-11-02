#include "whisper.h"
#include "include/whisper_bridge.h"
#include "ggml.h"
#include "ggml-backend.h"

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
    int using_gpu;
    int gpu_fallback;
    int64_t audio_ms;
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

// Metal 设备能否真正初始化。显卡被其他进程压满时 ggml_backend_dev_init 会返回 NULL，
// 但 whisper 仍会先把权重放到 Metal buffer，随后再用 CPU-only 调度器构图而 abort。
// 因此必须在加载模型前探测一次，不可用就整体回落 CPU。
static bool snwh_gpu_available(void) {
    for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        enum ggml_backend_dev_type type = ggml_backend_dev_type(dev);
        if (type != GGML_BACKEND_DEVICE_TYPE_GPU && type != GGML_BACKEND_DEVICE_TYPE_IGPU) continue;
        ggml_backend_t backend = ggml_backend_dev_init(dev, NULL);
        if (!backend) return false;
        ggml_backend_free(backend);
        return true;
    }
    return false;
}

snwh_context_t * snwh_load(const char * model_path, const char * vad_model_path,
                           char * err_buf, int err_len) {
    snwh_install_verbose_logging_if_requested();

    // residency set 在设备销毁时可能因缓冲区未释放而 assert；也避免长时间锁住显存。
    // 仅在用户未显式设置时生效（overwrite=0）。
    setenv("GGML_METAL_NO_RESIDENCY", "1", 0);

    struct whisper_context_params cparams = whisper_context_default_params();
    // SUBNOW_NO_GPU=1 → 强制 CPU（对照排障用）
    const char * no_gpu = getenv("SUBNOW_NO_GPU");
    if (no_gpu && no_gpu[0] == '1') {
        cparams.use_gpu = false;
    } else if (cparams.use_gpu && !snwh_gpu_available()) {
        fprintf(stderr, "[snwh] GPU 预检失败（设备无法初始化，常见于显存被占满），本次降级 CPU\n");
        cparams.use_gpu = false;
    }

    int gpu_fallback = 0;
    struct whisper_context * w = whisper_init_from_file_with_params(model_path, cparams);
    if (!w && cparams.use_gpu) {
        // 预检通过但真正建图失败：权重已在 GPU buffer、计算后端却没起来。
        // whisper 内部已改为返回失败而不是 abort，这里用纯 CPU 重建一次。
        fprintf(stderr, "[snwh] GPU 初始化失败，自动降级 CPU 重试\n");
        cparams.use_gpu = false;
        w = whisper_init_from_file_with_params(model_path, cparams);
        if (w) gpu_fallback = 1;
    }
    if (!w) {
        snprintf(err_buf, err_len, "模型加载失败: %s", model_path);
        return NULL;
    }
    struct snwh_context * c = (struct snwh_context *) calloc(1, sizeof(*c));
    if (!c) { whisper_free(w); snprintf(err_buf, err_len, "内存不足"); return NULL; }
    c->wctx = w;
    c->using_gpu = cparams.use_gpu;
    c->gpu_fallback = gpu_fallback;
    if (gpu_fallback) {
        fprintf(stderr, "[snwh] 已降级 CPU（性能低于 Metal，但结果一致）\n");
    }
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
    ctx->audio_ms = (int64_t) n_samples * 1000 / WHISPER_SAMPLE_RATE;
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

// whisper 内部时间单位是厘秒（10ms），桥对外统一毫秒（见 whisper_bridge.h）。
// 漏乘 10 会让整条时间轴压缩十倍：45 分钟的片子只显示到 4 分半。
int64_t snwh_segment_t0(snwh_context_t * ctx, int i) {
    return ctx ? whisper_full_get_segment_t0(ctx->wctx, i) * 10 : 0;
}

int64_t snwh_segment_t1(snwh_context_t * ctx, int i) {
    return ctx ? whisper_full_get_segment_t1(ctx->wctx, i) * 10 : 0;
}

const char * snwh_segment_text(snwh_context_t * ctx, int i) {
    return ctx ? whisper_full_get_segment_text(ctx->wctx, i) : "";
}

int snwh_uses_gpu(snwh_context_t * ctx) {
    return ctx ? ctx->using_gpu : 0;
}

int64_t snwh_audio_ms(snwh_context_t * ctx) {
    return ctx ? ctx->audio_ms : 0;
}

int snwh_gpu_fallback(snwh_context_t * ctx) {
    return ctx ? ctx->gpu_fallback : 0;
}

const char * snwh_detected_language(snwh_context_t * ctx) {
    return ctx ? ctx->language : "auto";
}
