import Foundation

/// 视频文件探测：内嵌字幕流语言（ffprobe）+ 同名外挂字幕扫描。
/// 判定规则：无外挂 且 无中文内嵌轨 → 需要生成。
enum VideoProbe {
    static let videoExtensions: Set<String> = [
        ".mkv", ".mp4", ".m4v", ".avi", ".mov", ".webm", ".ts", ".m2ts", ".mts",
        ".flv", ".wmv", ".mpg", ".mpeg", ".vob", ".ogv", ".3gp", ".rm", ".rmvb",
    ]
    static let subtitleExtensions: Set<String> = [
        ".srt", ".ass", ".ssa", ".sub", ".sup", ".vtt", ".smi",
    ]
    /// mpv 可能给 ISO 639-2（chi）或 BCP-47（zh-Hans-CN、cmn-Hant），只看主语言子标签。
    static let chinesePrimaryLanguages: Set<String> = ["zh", "chi", "zho", "cmn", "yue"]

    static func isChineseLanguage(_ tag: String) -> Bool {
        let normalized = tag.lowercased().replacingOccurrences(of: "_", with: "-")
        guard let primary = normalized.split(separator: "-").first else { return false }
        return chinesePrimaryLanguages.contains(String(primary))
    }

    struct VideoFacts {
        let embeddedChinese: Bool   // 内嵌中文字幕轨
        let hasSidecar: Bool        // 同名外挂字幕（任意语言——英字视频不打扰）
        let sidecarIsChinese: Bool  // 外挂文件名带中文线索（仅参考）
        var needsChineseSubtitle: Bool { !embeddedChinese && !hasSidecar }
    }

    // MARK: - 外挂字幕扫描

    /// 同名外挂：stem 精确 / stem. / stem- / stem_ 前缀；另查 Subs/ 子目录（前缀即可）。
    /// 任意语言的外挂都算"有字幕"——英字视频不触发（防止重复打扰）。
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

    static func embeddedSubtitleLanguages(of video: URL, ffprobeURL: URL?) -> [String] {
        guard let ffprobeURL else { return [] }
        let ffprobe = ffprobeURL

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
            // 60s 上限，防网络挂载盘卡死轮询
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
                return (s["language"] as? String)?.lowercased()
            }
        } catch {
            return []
        }
    }

    /// 媒体总时长（秒）。网络挂载盘可能卡住：8 秒超时，失败返回 nil。
    /// 调用方必须在后台线程使用（同步阻塞）。
    static func durationSeconds(of video: URL, ffprobeURL: URL?) -> TimeInterval? {
        guard let ffprobeURL else { return nil }

        let p = Process()
        p.executableURL = ffprobeURL
        p.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=nw=1:nk=1",
            video.path,
        ]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice

        do {
            try p.run()
            let deadline = DispatchTime.now() + 8
            let done = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in done.signal() }
            if !p.isRunning { done.signal() }  // 极小文件可能在 handler 安装前就退出
            if done.wait(timeout: deadline) == .timedOut {
                p.terminate()
                return nil
            }
            guard p.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  let seconds = Double(text), seconds.isFinite, seconds > 0 else { return nil }
            return seconds
        } catch {
            return nil
        }
    }

    // MARK: - 综合

    /// 异步探测：ffprobe 可能因网络挂载盘卡住数十秒，必须离开 MainActor。
    /// 按 path|size|mtime 缓存内嵌轨语言，轮询时同一文件只探测一次。
    static func facts(for video: URL, ffprobeURL: URL?) async -> VideoFacts {
        let sidecar = sidecarExists(for: video)
        let key = cacheKey(for: video)
        let langs: [String]
        if let cached = await ProbeCache.shared.languages(for: key) {
            langs = cached
        } else {
            langs = await Task.detached(priority: .utility) {
                embeddedSubtitleLanguages(of: video, ffprobeURL: ffprobeURL)
            }.value
            await ProbeCache.shared.store(langs, for: key)
        }
        let embeddedZH = langs.contains { isChineseLanguage($0) }
        return VideoFacts(embeddedChinese: embeddedZH, hasSidecar: sidecar.exists,
                          sidecarIsChinese: sidecar.isChinese)
    }

    /// 文件指纹：路径 + 大小 + 修改时间；任一变化即重新探测。
    static func cacheKey(for video: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: video.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(video.path)|\(size)|\(mtime)"
    }

    static func isVideoFile(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased().withLeadingDot)
    }
}

/// 探测缓存：只保存内嵌轨语言（外挂字幕随时可能出现，必须实时扫描）。
actor ProbeCache {
    static let shared = ProbeCache()
    private var entries: [String: [String]] = [:]
    private var order: [String] = []
    private let capacity = 200

    func languages(for key: String) -> [String]? { entries[key] }

    func store(_ languages: [String], for key: String) {
        if entries.updateValue(languages, forKey: key) == nil {
            order.append(key)
            if order.count > capacity {
                entries.removeValue(forKey: order.removeFirst())
            }
        }
    }
}

private extension String {
    var withLeadingDot: String { hasPrefix(".") ? self : "." + self }
}
