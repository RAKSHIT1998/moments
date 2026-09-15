import Foundation
import NaturalLanguage

/// Who said a unit of text. Drives promise direction and gift attribution.
enum Speaker: Equatable, Sendable {
    case user
    case other(String)
    case unknown

    var name: String? { if case .other(let n) = self { return n } else { return nil } }
}

/// One analyzable chunk: a chat message, a sentence, or a list item.
struct TextUnit: Equatable, Sendable {
    var text: String
    var speaker: Speaker
    var index: Int
}

struct NormalizedText: Sendable {
    var cleanedText: String
    var units: [TextUnit]
    var conversationWith: String?
    var isChat: Bool
    var chatApp: String?
    var urls: [URL]
}

/// Turns raw OCR/transcript/typed text into clean units with speaker attribution.
/// Screenshot chrome (status bar, "Delivered", timestamps) is treated as noise, not memory.
struct TextNormalizer: Sendable {
    var knownPeople: [PersonSnapshot] = []

    private static let noiseLinePatterns: [String] = [
        #"^\d{1,2}:\d{2}(\s?[AP]M)?$"#,                       // 9:41, 10:32 PM
        #"^(\d{1,3}%|[0-9]{1,3}\s?%)$"#,                        // 100%
        #"^(5G|4G|LTE|3G|E|Wi-?Fi|WiFi)$"#,
        #"^(delivered|read|seen|sent|edited|forwarded|replied|typing\.{0,3}|online|offline|active now|last seen.*|today|yesterday|now)$"#,
        #"^(imessage|text message|sms|message|type a message|write a message|send a message|whatsapp|telegram|messages|instagram|slack|signal|messenger)$"#,
        #"^(mon|tue|wed|thu|fri|sat|sun)(day|sday|nesday|rsday|urday)?$"#,
        #"^(back|home|search|more|call|video|info|share|reply|copy|save|cancel|done|edit|select|menu|new chat|chats|status|calls|updates|communities|settings|camera|gallery|photos|library)$"#,
        #"^[<>«»‹›•·\-–—_=+*#|\\/~^,.:;'"`]{1,4}$"#,
        #"^(read\s+)?\d{1,2}:\d{2}\s?[AP]?M?\s*✓{0,2}$"#,
        #"^\(?\d{1,4}\)?$"#,                                    // stray numbers (message counts)

    ]

    private static let chatAppHints: [(pattern: String, app: String)] = [
        ("whatsapp", "WhatsApp"), ("imessage", "Messages"), ("telegram", "Telegram"), ("instagram", "Instagram"),
        ("messenger", "Messenger"), ("slack", "Slack"), ("signal", "Signal"), ("snapchat", "Snapchat")
    ]

    private static let vocatives: Set<String> = ["bro", "dude", "man", "bruh", "buddy", "mate", "yaar", "yar", "bhai", "babe", "baby", "hey", "hi", "hello", "lol", "haha", "ok", "okay", "yes", "no", "yeah", "you", "me", "i", "we", "they", "he", "she", "it", "sir", "madam", "ma'am"]

    func normalize(_ raw: String, sourceType: SourceType, hints: [String: String] = [:]) -> NormalizedText {
        let urls = extractURLs(raw)
        let lines = raw.components(separatedBy: .newlines).map { $0.trimmed }.filter { !$0.isEmpty }
        let isImageLike = sourceType == .screenshot || sourceType == .scan || sourceType == .photo || sourceType == .shareSheet
        let looksLikeChat = isImageLike && detectChatStructure(lines)

        var chatApp: String?
        for (pattern, app) in Self.chatAppHints where raw.lowercased().contains(pattern) { chatApp = app; break }
        if let hinted = hints["chatApp"] { chatApp = hinted }

        if looksLikeChat {
            return normalizeChat(lines: lines, chatApp: chatApp, urls: urls)
        }

        // Prose / voice / typed text → sentences (and list items inside sentences).
        let cleaned = isImageLike ? lines.filter { !isNoise($0) }.joined(separator: "\n") : raw
        let sentences = splitSentences(cleaned)
        let units = sentences.enumerated().map { TextUnit(text: $0.element, speaker: .user, index: $0.offset) }
        return NormalizedText(cleanedText: cleaned, units: units, conversationWith: nil, isChat: false, chatApp: chatApp, urls: urls)
    }

    // MARK: - Chat handling

    private func detectChatStructure(_ lines: [String]) -> Bool {
        guard lines.count >= 2 else { return false }
        let noise = lines.filter(isNoise).count
        let hasSenderPrefix = lines.contains { $0.matches(#"^[A-Z][a-zA-Z .'-]{1,30}:\s+\S"#, caseSensitive: true) }
        let hasTimestamps = lines.filter { $0.matches(#"\b\d{1,2}:\d{2}\s?([AP]M)?\b"#) }.count >= 2
        let hasChatWords = lines.contains { $0.matches(#"^(imessage|delivered|read|text message|type a message|online|last seen)"#) }
        let headerName = headerParticipant(lines) != nil
        return hasSenderPrefix || hasChatWords || (hasTimestamps && headerName) || (noise >= 2 && headerName)
    }

    /// The first line that looks like a person's name (chat header). Known people win.
    private func headerParticipant(_ lines: [String]) -> String? {
        for line in lines.prefix(6) where !isNoise(line) {
            let cleaned = line.replacingOccurrences(of: #"[<>›»]"#, with: "", options: .regularExpression).trimmed
            if let known = knownPeople.first(where: { p in p.allNames.contains(cleaned.lowercased()) || cleaned.lowercased().hasPrefix(p.displayName.lowercased() + " ") }) {
                return known.displayName
            }
            if looksLikeName(cleaned) { return cleaned }
        }
        return nil
    }

    func looksLikeName(_ s: String) -> Bool {
        let words = s.split(separator: " ").map(String.init)
        guard (1...3).contains(words.count), s.count <= 32 else { return false }
        guard words.allSatisfy({ $0.first?.isUppercase == true && $0.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" || $0 == "." } }) else { return false }
        guard !Self.vocatives.contains(words[0].lowercased()) else { return false }
        // Use NLTagger as a second opinion for single words.
        if words.count == 1 {
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = s
            let tag = tagger.tag(at: s.startIndex, unit: .word, scheme: .nameType).0
            if tag == .personalName { return true }
            // Unknown single capitalized word: accept only if it's not a dictionary-ish common word.
            return !EntityRecognizer.commonWords.contains(s.lowercased())
        }
        return true
    }

    private func normalizeChat(lines: [String], chatApp: String?, urls: [URL]) -> NormalizedText {
        let participant = headerParticipant(lines)
        var units: [TextUnit] = []
        var current: (speaker: Speaker, text: String)?
        var cleanedLines: [String] = []

        func flush() {
            if let c = current, !c.text.isBlank {
                let sentences = splitSentences(c.text)
                for s in sentences { units.append(TextUnit(text: s, speaker: c.speaker, index: units.count)) }
                cleanedLines.append((c.speaker.name.map { "\($0): " } ?? (c.speaker == .user ? "You: " : "")) + c.text)
            }
            current = nil
        }

        for (i, line) in lines.enumerated() {
            if isNoise(line) { continue }
            if i < 4, let participant, line.lowercased().contains(participant.lowercased()), line.count <= participant.count + 4 { continue } // header line

            // "[10/12/25, 9:41 PM] Sarah: text" (WhatsApp export) or "Sarah: text"
            if let m = line.firstMatch(#"^(?:\[[^\]]+\]\s*)?([A-Z][a-zA-Z .'-]{1,30}):\s+(.+)$"#, group: 1, caseSensitive: true),
               let body = line.firstMatch(#"^(?:\[[^\]]+\]\s*)?[A-Z][a-zA-Z .'-]{1,30}:\s+(.+)$"#, group: 1, caseSensitive: true) {
                flush()
                let lower = m.lowercased()
                let speaker: Speaker = (lower == "you" || lower == "me") ? .user : .other(m)
                current = (speaker, body)
                continue
            }
            // "You: text" / "Me: text"
            if let body = line.firstMatch(#"^(?:you|me):\s+(.+)$"#, group: 1) {
                flush(); current = (.user, body); continue
            }
            // Otherwise: continuation of the current bubble, or a new bubble from the participant.
            let stripped = line.replacingOccurrences(of: #"\s+\d{1,2}:\d{2}\s?([AP]M)?\s*✓{0,2}$"#, with: "", options: .regularExpression).trimmed
            if stripped.isEmpty { continue }
            if var c = current, c.text.count < 240, !stripped.matches(#"^[A-Z]"#, caseSensitive: true) || c.text.last.map({ !".!?".contains($0) }) == true {
                c.text += " " + stripped
                current = c
            } else {
                flush()
                current = (participant.map { .other($0) } ?? .unknown, stripped)
            }
        }
        flush()

        return NormalizedText(
            cleanedText: cleanedLines.joined(separator: "\n"),
            units: units,
            conversationWith: participant,
            isChat: true,
            chatApp: chatApp,
            urls: urls
        )
    }

    // MARK: - Helpers

    func isNoise(_ line: String) -> Bool {
        let l = line.trimmed
        if l.count <= 1 { return true }
        if l.strippingEmoji.isBlank { return true } // emoji-only lines
        return Self.noiseLinePatterns.contains { l.matches($0) }
    }

    func splitSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range]).collapsedWhitespace
            if !s.isEmpty { out.append(s) }
            return true
        }
        // Newlines inside a "sentence" (bullet lists) are separate units.
        return out.flatMap { $0.components(separatedBy: "\n").map { $0.trimmed }.filter { !$0.isEmpty } }
    }

    func extractURLs(_ text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).filter { $0.scheme?.hasPrefix("http") == true }
    }
}
