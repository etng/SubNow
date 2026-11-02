import Foundation

/// 字幕段落模型与时间/分行规则（固定实测参数）。
struct Segment: Codable {
    var start: Int      // 毫秒
    var end: Int        // 毫秒
    var src: String
    var zh: String?
}

struct SegmentsFile: Codable {
    let language: String
    var segments: [Segment]
}

enum Segments {
    /// BREAK_PUNCT：优先在这些符号处断行
    static let breakPunct: Set<Character> = ["、", "。", "，", "！", "？", "…", ",", ".", ";", ":",
                                             "!", "?", "）", "」", "』", "】", " "]
    static let cjkLanguages: Set<String> = ["ja", "zh", "ko", "yue"]

    static func isCJK(_ lang: String) -> Bool { cjkLanguages.contains(lang) }

    static func langName(_ lang: String) -> String {
        switch lang {
        case "ja": return "日语"
        case "en": return "英语"
        case "ko": return "韩语"
        case "zh": return "中文"
        case "yue": return "粤语"
        case "de": return "德语"
        case "fr": return "法语"
        case "ru": return "俄语"
        case "es": return "西班牙语"
        default: return "原语言"
        }
    }

    /// whisper 段文本清理：去掉首部标点/空白
    static func cleanText(_ raw: String) -> String {
        var s = Substring(raw)
        while let first = s.first, " \t.,，。、!！?？；;…".contains(first) {
            s = s.dropFirst()
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 预切长句：CJK 预算 lineLen+2，非 CJK 预算 lineLen*2+4；
    /// 优先在预算内最后一个断句符号处切（≥50% 预算），时长按字符数插值；随后 fix_timing。
    static func splitLong(_ segments: [Segment], language: String, lineLen: Int) -> [Segment] {
        let budget = isCJK(language) ? lineLen + 2 : lineLen * 2 + 4
        var result: [Segment] = []

        for seg in mergeFragments(segments, language: language) {
            let text = seg.src
            guard text.count > budget else {
                result.append(seg)
                continue
            }
            let pieces = splitText(text, budget: budget)
            let totalChars = pieces.reduce(0) { $0 + $1.count }
            guard totalChars > 0 else {
                result.append(seg)
                continue
            }
            // 时间不够分给每个碎片时不拆：否则每段都会被 fix_timing 拉长并严重重叠。
            let available = seg.end - seg.start
            guard available >= pieces.count * 800 else {
                result.append(seg)
                continue
            }
            let duration = max(available, pieces.count * 200)
            var cursor = seg.start
            for piece in pieces {
                let pieceDur = duration * piece.count / totalChars
                let pieceEnd = min(cursor + pieceDur, seg.end)
                result.append(Segment(start: cursor, end: pieceEnd, src: piece, zh: nil))
                cursor = pieceEnd
            }
            result[result.count - 1].end = seg.end  // 末段收尾对齐
        }
        return fixTiming(result)
    }

    /// whisper 偶尔会吐出几十毫秒的碎片（如“いただきたい”被切到 40ms），
    /// 两行字幕会闪一下。间隔很近时并入相邻行，保证至少可读。
    static func mergeFragments(_ input: [Segment], language: String) -> [Segment] {
        let cjk = isCJK(language)
        func join(_ a: String, _ b: String) -> String {
            a.isEmpty ? b : (b.isEmpty ? a : (cjk ? a + b : a + " " + b))
        }
        var segs = input.sorted { $0.start < $1.start }
        var i = 0
        while i < segs.count {
            guard segs[i].end - segs[i].start < 300 else { i += 1; continue }
            if i > 0, segs[i].start - segs[i - 1].end <= 200,
               segs[i - 1].end - segs[i - 1].start >= 300 {
                segs[i - 1].src = join(segs[i - 1].src, segs[i].src)
                segs[i - 1].zh = join(segs[i - 1].zh ?? "", segs[i].zh ?? "").nilIfEmpty
                segs[i - 1].end = max(segs[i - 1].end, segs[i].end)
                segs.remove(at: i)
                continue
            }
            if i + 1 < segs.count, segs[i + 1].start - segs[i].end <= 200 {
                segs[i].src = join(segs[i].src, segs[i + 1].src)
                segs[i].zh = join(segs[i].zh ?? "", segs[i + 1].zh ?? "").nilIfEmpty
                segs[i].end = max(segs[i].end, segs[i + 1].end)
                segs.remove(at: i + 1)
                continue
            }
            i += 1
        }
        return segs
    }

    private static func splitText(_ text: String, budget: Int) -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        while rest.count > budget {
            let head = rest.prefix(budget + 1)
            // 预算内最后一个断句符号（要求 ≥ 50% 预算处，避免碎片）
            var cut = head.lastIndex(where: { breakPunct.contains($0) })
            if let c = cut, head.distance(from: head.startIndex, to: c) < budget / 2 {
                cut = nil
            }
            if let c = cut {
                let piece = String(head[head.startIndex...c]).trimmingCharacters(in: .whitespaces)
                pieces.append(piece)
                rest = rest[rest.index(after: c)...]
            } else {
                let piece = String(rest.prefix(budget))
                pieces.append(piece)
                rest = rest[rest.index(rest.startIndex, offsetBy: budget)...]
            }
            rest = rest.drop { $0 == " " }
        }
        if !rest.isEmpty { pieces.append(String(rest)) }
        return pieces.filter { !$0.isEmpty }
    }

    /// 最短 800ms、最长 10s、相邻重叠修正。
    /// 按起点排序后再逐条收口：先保证不侵入下一条，再在可用空间内补到最短时长。
    /// 若下一条来得太快（间隔不足 800ms），宁可短一点也不重叠——重叠会让两行字叠在一起。
    static func fixTiming(_ input: [Segment]) -> [Segment] {
        var segs = input.sorted { $0.start < $1.start }
        for i in segs.indices {
            let start = max(segs[i].start, 0)
            var end = min(max(segs[i].end, start + 800), start + 10_000)
            if i + 1 < segs.count {
                let nextStart = segs[i + 1].start
                if nextStart > start {
                    end = min(end, nextStart - 20)
                }
            }
            segs[i].start = start
            segs[i].end = max(end, start + 1)
        }
        return segs
    }

    /// 渲染时限宽：中文行 40；原文行 CJK 40 / 其他 90。
    /// 窗口 = 限宽+1，窗口内最后断句符号（≥60% 处）优先，否则硬切。
    static func wrapLine(_ text: String, width: Int, joiner: String) -> String {
        guard text.count > width else { return text }
        var lines: [String] = []
        var rest = Substring(text)
        while rest.count > width {
            let window = rest.prefix(width + 1)
            var cut = window.lastIndex(where: { breakPunct.contains($0) })
            if let c = cut, window.distance(from: window.startIndex, to: c) < width * 6 / 10 {
                cut = nil
            }
            if let c = cut {
                lines.append(String(window[window.startIndex...c]).trimmingCharacters(in: .whitespaces))
                rest = rest[rest.index(after: c)...]
            } else {
                lines.append(String(rest.prefix(width)))
                rest = rest[rest.index(rest.startIndex, offsetBy: width)...]
            }
            rest = rest.drop { $0 == " " }
        }
        if !rest.isEmpty { lines.append(String(rest)) }
        return lines.joined(separator: joiner)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
