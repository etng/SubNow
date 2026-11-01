import Foundation
import WhisperBridge

// 用法: snprobe <model> <wav> [vad-model] [--lang xx]
let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("用法: snprobe <model> <wav> [vad] [--lang xx]\n".data(using: .utf8)!)
    exit(2)
}
let model = args[1], wav = args[2]
var vad: String? = nil
var lang = "auto"
var i = 3
while i < args.count {
    if args[i] == "--lang", i + 1 < args.count { lang = args[i + 1]; i += 2 }
    else { vad = args[i]; i += 1 }
}

var err = [CChar](repeating: 0, count: 1024)
guard let ctx = model.withCString({ snwh_load($0, vad, &err, 1024) }) else {
    print("加载失败: \(String(cString: err))")
    exit(1)
}
defer { snwh_free(ctx) }

let t0 = Date()
let rc = wav.withCString { w in
    lang.withCString { l in
        snwh_run(ctx, w, l, nil, nil, nil, nil, &err, 1024)
    }
}
let secs = -t0.timeIntervalSinceNow
if rc != 0 {
    print("run 失败 rc=\(rc): \(String(cString: err))")
    exit(1)
}
let langPtr = snwh_detected_language(ctx)
print("语言: \(langPtr.map { String(cString: $0) } ?? "?")  耗时: \(String(format: "%.2f", secs))s  分段: \(snwh_segment_count(ctx))")
for i in 0..<snwh_segment_count(ctx) {
    let t0ms = snwh_segment_t0(ctx, i), t1ms = snwh_segment_t1(ctx, i)
    let text = snwh_segment_text(ctx, i).map { String(cString: $0) } ?? ""
    print(String(format: "[%6.2f → %6.2f] %@", Double(t0ms) / 1000, Double(t1ms) / 1000, text.trimmingCharacters(in: .whitespaces)))
}
