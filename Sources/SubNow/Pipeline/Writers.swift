import Foundation

/// 字幕文件写入：SRT（原文/纯中文）与双语 ASS（正排/反排）。
/// ASS 样式沿用成熟压制字幕的画布：PlayRes 384×288、中文 20、原文 14、描边/阴影 1。
enum Writers {
    // MARK: - 时间戳

    static func tsSrt(_ ms: Int) -> String {
        let totalSec = max(ms, 0) / 1000
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        let millis = max(ms, 0) % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, millis)
    }

    /// ASS 时间：H:MM:SS.CC（小时不补零）
    static func tsAss(_ ms: Int) -> String {
        let cs = max(ms, 0) / 10
        let h = cs / 360_000
        let m = (cs % 360_000) / 6_000
        let s = (cs % 6_000) / 100
        let c = cs % 100
        return String(format: "%d:%02d:%02d.%02d", h, m, s, c)
    }

    // MARK: - SRT

    static func writeSrt(_ segments: [Segment], language: String, to url: URL, mode: SrtMode) throws {
        var out = ""
        for (i, seg) in segments.enumerated() {
            let body: String
            switch mode {
            case .original:
                body = Segments.wrapLine(seg.src, width: Segments.isCJK(language) ? 40 : 90, joiner: "\n")
            case .chinese:
                body = Segments.wrapLine(seg.zh ?? seg.src, width: 40, joiner: "\n")
            }
            out += "\(i + 1)\n\(tsSrt(seg.start)) --> \(tsSrt(seg.end))\n\(body)\n\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    enum SrtMode { case original, chinese }

    // MARK: - ASS

    static func assHeader() -> String {
        """
        [Script Info]
        ScriptType: v4.00+
        Collisions: Reverse
        PlayResX: 384
        PlayResY: 288
        WrapStyle: 0
        ScaledBorderAndShadow: no

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Zh,PingFang SC,20,&H00FFFFFF,&H000000FF,&H00000000,&H96000000,1,0,0,0,100,100,0,0,1,1,1,2,0,0,8,1
        Style: Org,PingFang SC,14,&H0050A8D0,&H000000FF,&H00000000,&H96000000,1,0,0,0,100,100,0,0,1,1,1,2,0,0,8,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        """
    }

    /// ASS 文本转义：`\`、`{`、`}` 会被当作覆写标签，必须先转义再分行。
    static func escapeAss(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
    }

    /// 双语 ASS。zhFirst=true：中文第 1 行（白）；false：原文在上（zh-bottom 变体）。
    static func writeBilingualAss(_ segments: [Segment], language: String, to url: URL, zhFirst: Bool) throws {
        var out = assHeader() + "\n"
        // 384 宽画布下：中文 20px 约 19 字/行；原文 14px 约 52 字符/行
        let orgWidth = Segments.isCJK(language) ? 18 : 50
        for seg in segments {
            let zh = Segments.wrapLine(escapeAss(seg.zh ?? ""), width: 18, joiner: "\\N")
            let org = Segments.wrapLine(escapeAss(seg.src), width: orgWidth, joiner: "\\N")
            let text: String
            if zhFirst {
                text = "{\\rZh}\(zh)\\N{\\rOrg}\(org)"
            } else {
                text = "{\\rOrg}\(org)\\N{\\rZh}\(zh)"
            }
            out += "Dialogue: 0,\(tsAss(seg.start)),\(tsAss(seg.end)),Zh,,0,0,0,,\(text)\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - segments.json（增量可见）

    static func writeSegmentsFile(_ segments: [Segment], language: String, to url: URL) throws {
        let file = SegmentsFile(language: language, segments: segments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        try data.write(to: url, options: .atomic)
    }

    /// 从既有 segments.json 恢复（秒级改样式重出 / 复跑翻译跳过已完成行）
    static func readSegmentsFile(from url: URL) -> SegmentsFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SegmentsFile.self, from: data)
    }

    /// 原文 SRT 文件名：中文源不要再写 `.<lang>.srt`，否则会与最终 `<stem>.zh.srt` 同名覆盖。
    static func originalSrtName(stem: String, language: String) -> String {
        language == "zh" ? "\(stem).orig.srt" : "\(stem).\(language).srt"
    }
}
