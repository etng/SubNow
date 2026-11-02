#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// SubNow ↔ whisper.cpp 稳定 C 桥。
// 约定：音频为 16kHz 单声道 PCM16 WAV（由 ffmpeg 提取）；时间单位一律毫秒。

typedef struct snwh_context snwh_context_t;

typedef void (*snwh_progress_fn)(void *userdata, int percent);   // percent: 0-100
typedef bool (*snwh_abort_fn)(void *userdata);                   // 返回 false = 中止

// 加载模型。vad_model_path 可为 NULL 或 ""（不启用 VAD）。
// 失败返回 NULL，并把错误写入 err_buf。
snwh_context_t * snwh_load(const char *model_path,
                           const char *vad_model_path,
                           char *err_buf, int err_len);

void snwh_free(snwh_context_t *ctx);

// 转录。返回 0 成功 / -1 失败（err_buf 填原因）/ -2 用户中止。
int snwh_run(snwh_context_t *ctx,
             const char *wav_path,
             const char *language,          // NULL/"auto" = 自动检测，否则 ISO 代码
             snwh_progress_fn progress_fn, void *progress_ud,
             snwh_abort_fn abort_fn, void *abort_ud,
             char *err_buf, int err_len);

int          snwh_segment_count(snwh_context_t *ctx);
int64_t      snwh_segment_t0(snwh_context_t *ctx, int i);   // 毫秒（whisper 的厘秒已在桥内换算）
int64_t      snwh_segment_t1(snwh_context_t *ctx, int i);   // 毫秒
const char * snwh_segment_text(snwh_context_t *ctx, int i);
// 本次识别出的语言（ISO 代码）；自动检测失败时返回 "auto"。
const char * snwh_detected_language(snwh_context_t *ctx);

// 实际使用的计算后端：1 = GPU(Metal)，0 = CPU。
int snwh_uses_gpu(snwh_context_t *ctx);
// 本次转录的音频总时长（毫秒），用于校验时间轴是否完整。
int64_t snwh_audio_ms(snwh_context_t *ctx);
// 本次是否从 GPU 自动降级到了 CPU（1 = 发生过降级，用于日志与后续排障）。
int snwh_gpu_fallback(snwh_context_t *ctx);

#ifdef __cplusplus
}
#endif
