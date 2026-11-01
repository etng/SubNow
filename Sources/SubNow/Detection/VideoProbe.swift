import Foundation

/// 视频文件探测：内嵌字幕流语言（ffprobe）+ 同名外挂字幕扫描。
/// 判定规则与POC 调研结果一致：无外挂 且 无中文内嵌轨 → 需要生成。
enum VideoProbe {
    static let videoExtensions: Set<String> = [
        ".mkv", ".mp4", ".m4v", ".avi", ".mov", ".webm", ".ts", ".m2ts", ".mts",
        ".flv", ".wmv", ".mpg", ".mpeg", ".vob", ".ogv", ".3gp", ".rm", ".rmvb",
    ]
    static let subtitleExtensions: Set<String> = [
        ".srt", ".ass", ".ssa", ".sub", ".sup", ".vtt", ".smi",
    ]
    static let zhLanguages: Set<String> = ["zh", "chi", "zho"]

    struct VideoFacts {
        let embeddedChinese: Bool   // 内嵌中文字幕轨
        let hasSidecar: Bool        // 同名外挂字幕（任意语言——英字视频不打扰）
        let sidecarIsChinese: Bool  // 外挂文件名带中文线索（仅参考）
        var needsChineseSubtitle: Bool { !embeddedChinese && !hasSidecar }
    }

    // MARK: - 外挂字幕扫描

    /// 同名外挂：stem 精确 / stem. / stem- / stem_ 前缀；另查 Subs/ 子目录（前缀即可）。
    /// 任意语言的外挂都算"有字幕"——英字视频不触发（POC 调研结果语义，防止重复打扰）。
    static func sidecarExists(for video: URL) -> (exists: Bool, isChinese: Bool) {
        let dir = video.deletingLastPathComponent()
        let stem = video.deletingPathExtension().lastPathComponent
        let subsDir = dir.appendingPathComponent("Subs", isDirectory: true)

        var candidates = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        candidates += (try? FileManager.default.contentsOfDirectory(at: subsDir, includingPropertiesForKeys: nil)) ?? []

        for f in candidates {
            guard subtitleExtensions.contains(f.pathExtension.lowercased().withLeadingDot) else { continue }
            let fStem = f.deletingPathExtension().lastPathComponent
            let matched = fStem == stem
                || fStem.hasPrefix(stem + ".")
                || fStem.hasPrefix(stem + "-")
                || fStem.hasPrefix(stem + "_")
                || (f.deletingLastPathComponent() == subsDir && fStem.hasPrefix(stem))
            if matched {
                return (true, looksChinese(fStem))
            }
        }
        return (false, false)
    }

    /// 文件名中文线索（仅展示用，判定不依赖）
    static func looksChinese(_ filename: String) -> Bool {
        let lowered = filename.lowercased()
        let keywords = ["zh", "chi", "zho", "chs", "cht", "sc", "gb", "big5", "简", "繁", "中字", "中文", "中英"]
        return keywords.contains { lowered.contains($0) } || filename.contains("简") || filename.contains("繁")
    }

    // MARK: - 内嵌字幕轨（ffprobe）

    static func embeddedSubtitleLanguages(of video: URL, ffmpegURL: URL?) -> [String] {
        guard let ffmpegURL else { return [] }
        let ffprobe = ffmpegURL.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffprobe.path) else { return [] }

        let p = Process()
        p.executableURL = ffprobe
        p.arguments = [
            "-v", "error",
            "-show_entries", "stream=codec_type,codec_name:stream_tags=language,title",
            "-of", "json", video.path,
        ]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice

        do {
            try p.run()
            // 60s 上限（POC 调研结果同款），防网络挂载盘卡死轮询
            let deadline = DispatchTime.now() + 60
            let done = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in done.signal() }
            if done.wait(timeout: deadline) == .timedOut {
                p.terminate()
                return []
            }
            guard p.terminationStatus == 0 else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let streams = obj["streams"] as? [[String: Any]] else { return [] }
            return streams.compactMap { s in
                guard (s["codec_type"] as? String) == "subtitle" else { return nil }
                return (s["language"] as? String)?.split(separator: "-").first.map(String.init)?.lowercased()
            }
        } catch {
            return []
        }
    }

    // MARK: - 综合

    static func facts(for video: URL, ffmpegURL: URL?) -> VideoFacts {
        let sidecar = sidecarExists(for: video)
        let langs = embeddedSubtitleLanguages(of: video, ffmpegURL: ffmpegURL)
        let embeddedZH = langs.contains { zhLanguages.contains($0) }
        return VideoFacts(embeddedChinese: embeddedZH, hasSidecar: sidecar.exists,
                          sidecarIsChinese: sidecar.isChinese)
    }

    static func isVideoFile(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased().withLeadingDot)
    }
}

private extension String {
    var withLeadingDot: String { hasPrefix(".") ? self : "." + self }
}
