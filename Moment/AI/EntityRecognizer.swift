import Foundation
import NaturalLanguage

/// Finds people, places, and objects in text. NaturalLanguage first, then conservative heuristics.
/// Known people/places from the user's own store always win over guesses.
struct EntityRecognizer: Sendable {
    var context: AnalysisContext

    struct Entities: Sendable, Equatable {
        var people: [String] = []
        var places: [String] = []
        var organizations: [String] = []
        var statedRelationships: [String: String] = [:]   // name → "brother"
    }

    /// Words that look like names when capitalized at sentence start but aren't.
    static let commonWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "so", "if", "then", "when", "where", "what", "who", "why", "how", "this", "that", "these", "those",
        "i", "you", "we", "they", "he", "she", "it", "my", "your", "our", "their", "his", "her", "its", "me", "us", "them",
        "let", "lets", "let's", "go", "going", "come", "get", "got", "need", "want", "will", "would", "should", "could", "can", "did", "do", "does",
        "remind", "reminder", "remember", "forget", "call", "text", "send", "book", "buy", "try", "visit", "see", "check", "plan", "plans",
        "today", "tomorrow", "tonight", "yesterday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "ok", "okay", "yes", "no", "yeah", "yep", "nope", "sure", "thanks", "thank", "please", "sorry", "hey", "hi", "hello", "bye", "lol", "haha", "omg", "btw",
        "bro", "dude", "man", "bruh", "buddy", "mate", "yaar", "bhai", "babe", "baby", "sir",
        "also", "just", "really", "very", "maybe", "probably", "definitely", "actually", "still", "already", "again", "never", "always",
        "trip", "gift", "birthday", "dinner", "lunch", "brunch", "coffee", "meeting", "party", "wedding", "flight", "hotel", "restaurant", "cafe",
        "new", "old", "big", "small", "good", "bad", "great", "nice", "best", "next", "last", "first", "one", "two", "three",
        "passport", "car", "shop", "house", "home", "office", "work", "school", "gym", "property", "number", "contact", "guy", "girl", "uncle", "aunt", "mom", "dad",
        "december", "wow", "cool", "nice", "done", "love", "like", "hate", "wish", "hope", "think", "thought", "know", "said", "says", "told", "tell",
        "shoes", "watch", "bag", "phone", "book", "books", "headphones", "jacket", "dress", "perfume", "ring", "laptop", "camera",
        "goa", "bali", "manali", "paris", "london", "tokyo", "dubai", "delhi", "mumbai", "bangalore", // handled as places, never people
        "japanese", "italian", "korean", "thai", "mexican", "chinese", "indian", "lebanese", "mediterranean", "french", "american", "vietnamese", "greek", "turkish", "spanish", "german", "british", "european", "asian", "continental", "punjabi", "south", "north", "goan", "bengali", "gujarati", "keralan", "hyderabadi", "mughlai", "andhra", "chettinad", "tibetan", "nepali", "burmese", "malaysian", "indonesian", "filipino", "peruvian", "brazilian", "ethiopian", "moroccan", "persian", "iranian", "afghan", "pakistani", "sri", "lankan"
    ]

    static let relationshipNouns: [String] = ["brother", "sister", "mom", "mother", "dad", "father", "wife", "husband", "partner", "boyfriend", "girlfriend", "fiancé", "fiancee", "fiance", "boss", "manager", "cousin", "uncle", "aunt", "grandma", "grandmother", "grandpa", "grandfather", "friend", "best friend", "colleague", "coworker", "roommate", "flatmate", "neighbour", "neighbor", "son", "daughter", "nephew", "niece", "landlord", "doctor", "dentist", "trainer", "teacher", "mentor"]

    /// Small gazetteer of destinations people commonly plan trips to; NLTagger misses several.
    static let knownDestinations: Set<String> = [
        "goa", "bali", "manali", "kerala", "ladakh", "leh", "jaipur", "udaipur", "shimla", "rishikesh", "mussoorie", "coorg", "ooty", "pondicherry", "puducherry", "varanasi", "agra", "hampi", "andaman", "lakshadweep", "sikkim", "darjeeling", "gokarna", "lonavala", "alibaug", "nainital", "kasol", "spiti", "kashmir", "srinagar", "gulmarg", "munnar", "wayanad", "mysore", "hyderabad", "chennai", "kolkata", "pune", "delhi", "mumbai", "bangalore", "bengaluru", "ahmedabad", "chandigarh", "lucknow", "kochi", "goa",
        "paris", "london", "tokyo", "kyoto", "dubai", "singapore", "bangkok", "phuket", "maldives", "sri lanka", "nepal", "bhutan", "vietnam", "hanoi", "da nang", "seoul", "new york", "nyc", "los angeles", "san francisco", "seattle", "chicago", "miami", "vegas", "las vegas", "toronto", "vancouver", "mexico", "cancun", "lisbon", "porto", "barcelona", "madrid", "rome", "milan", "florence", "venice", "amsterdam", "berlin", "prague", "vienna", "budapest", "athens", "santorini", "istanbul", "cappadocia", "cairo", "marrakech", "cape town", "nairobi", "zanzibar", "sydney", "melbourne", "auckland", "queenstown", "iceland", "reykjavik", "norway", "switzerland", "zurich", "interlaken", "scotland", "edinburgh", "ireland", "dublin", "greece", "italy", "spain", "portugal", "france", "japan", "thailand", "indonesia", "turkey", "egypt", "morocco", "australia", "new zealand", "hawaii", "europe", "himalayas", "alps", "amalfi", "tuscany", "bora bora", "fiji", "mauritius", "seychelles"
    ]

    static let placeKindKeywords: [(kind: String, pattern: String)] = [
        ("restaurant", #"\b(restaurant|dinner|lunch|brunch|eat|food|cuisine|sushi|ramen|pizza|tacos|omakase|dine|dining|bistro|diner|eatery)\b"#),
        ("cafe", #"\b(cafe|café|coffee|espresso|bakery|patisserie)\b"#),
        ("bar", #"\b(bar|pub|brewery|cocktails?|drinks)\b"#),
        ("hotel", #"\b(hotel|resort|villa|airbnb|hostel|stay|staycation)\b"#),
        ("shop", #"\b(shop|store|boutique|mall|market)\b"#),
        ("airport", #"\b(airport|terminal)\b"#),
        ("venue", #"\b(venue|club|theatre|theater|stadium|arena|gallery|museum|concert|hall)\b"#),
        ("city", #"\b(trip|travel|fly|flight|visit|vacation|holiday|go to|going to|weekend in)\b"#)
    ]

    func recognize(in text: String, speaker: Speaker) -> Entities {
        var out = Entities()
        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])
        tagger.string = text
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]

        var taggedPeople: [String] = []
        var taggedPlaces: [String] = []
        var taggedOrgs: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            let token = String(text[range])
            switch tag {
            case .personalName?: taggedPeople.append(token)
            case .placeName?: taggedPlaces.append(token)
            case .organizationName?: taggedOrgs.append(token)
            default: break
            }
            return true
        }

        // Known people (store) — match by name/alias anywhere, case-insensitive whole word.
        for person in context.knownPeople {
            for name in [person.displayName] + person.aliases where !name.isEmpty && text.containsWord(name) {
                out.people.append(person.displayName)
                break
            }
        }
        // Corrections: "rahul from gym" → canonical
        for (fromText, id) in context.personCorrections where text.lowercased().contains(fromText) {
            if let p = context.knownPeople.first(where: { $0.id == id }) { out.people.append(p.displayName) }
        }

        // Tagged people, filtered.
        for name in taggedPeople {
            let clean = name.trimmed
            guard isPlausiblePersonName(clean) else { continue }
            out.people.append(canonicalPersonName(clean))
        }

        // "my brother Rahul" / "Rahul, my cousin"
        let relPattern = "\\b(?:[Mm]y|[Oo]ur)\\s+(" + Self.relationshipNouns.joined(separator: "|") + ")\\s+([A-Z][a-z]+)"
        if let rel = text.firstMatch(relPattern, group: 1, caseSensitive: true), let name = text.firstMatch(relPattern, group: 2, caseSensitive: true), isPlausiblePersonName(name) {
            out.people.append(canonicalPersonName(name))
            out.statedRelationships[canonicalPersonName(name)] = rel.lowercased()
        }
        let relPattern2 = "\\b([A-Z][a-z]+),?\\s+(?:[Mm]y|[Oo]ur)\\s+(" + Self.relationshipNouns.joined(separator: "|") + ")\\b"
        if let name = text.firstMatch(relPattern2, group: 1, caseSensitive: true), let rel = text.firstMatch(relPattern2, group: 2, caseSensitive: true), isPlausiblePersonName(name) {
            out.people.append(canonicalPersonName(name))
            out.statedRelationships[canonicalPersonName(name)] = rel.lowercased()
        }

        // Possessives and typical subject positions: "Sarah's birthday", "Sarah wants", "call Rahul", "with Priya"
        for m in text.allMatches(#"\b([A-Z][a-z]{2,}(?:\s[A-Z][a-z]+)?)(?:'s\b|\s+(?:wants?|wanted|said|says|mentioned|told|asked|likes?|liked|loves?|loved|promised|owes|suggested|recommended|is|was|will|has|had)\b)"#, group: 1, caseSensitive: true) where isPlausiblePersonName(m) {
            out.people.append(canonicalPersonName(m))
        }
        for m in text.allMatches(#"\b(?:call|text|ask|tell|meet|with|for|remind|ping|email|message|visit|send|give|bring|pay|show|forward|owe|thank)\s+([A-Z][a-z]{2,})\b"#, group: 1, caseSensitive: true) where isPlausiblePersonName(m) {
            out.people.append(canonicalPersonName(m))
        }

        // The speaker themselves is a person in the conversation.
        if case .other(let name) = speaker { out.people.append(canonicalPersonName(name)) }

        // Places
        for p in taggedPlaces where !isPersonNameConflict(p, people: out.people) { out.places.append(p.trimmed) }
        for word in text.allMatches(#"\b([A-Z][a-zA-Z]+(?:\s[A-Z][a-zA-Z]+)?)\b"#, group: 1, caseSensitive: true) {
            let lower = word.lowercased()
            if Self.knownDestinations.contains(lower), !out.places.contains(where: { $0.lowercased() == lower }) { out.places.append(word) }
        }
        // Lowercase destination mentions ("goa in december")
        for dest in Self.knownDestinations where text.lowercased().containsWord(dest) && !out.places.contains(where: { $0.lowercased() == dest }) {
            out.places.append(dest.capitalized)
        }
        for place in context.knownPlaces where text.containsWord(place.name) && !out.places.contains(where: { $0.lowercased() == place.name.lowercased() }) {
            out.places.append(place.name)
        }
        // "try Tosaka", "at Tosaka", "called Tosaka", "place called X"
        for m in text.allMatches(#"\b(?:try|tried|at|called|named|to|visit|book|went to|go to)\s+([A-Z][a-zA-Z'&-]+(?:\s[A-Z][a-zA-Z'&-]+){0,2})\b"#, group: 1, caseSensitive: true) {
            let lower = m.lowercased()
            guard !Self.commonWords.contains(lower), !out.people.contains(where: { $0.lowercased() == lower }), !out.places.contains(where: { $0.lowercased() == lower }) else { continue }
            guard !isPlausiblePersonName(m) || Self.knownDestinations.contains(lower) else { continue }
            out.places.append(m)
        }

        // Restaurant/cafe/bar context with no place yet: the capitalized thing being mentioned/recommended is the place.
        let kind = Self.placeKind(for: text)
        if out.places.isEmpty, ["restaurant", "cafe", "bar", "hotel", "shop", "venue"].contains(kind) {
            for m in text.allMatches(#"\b(?:mentioned|recommended|suggested|try|tried|loves?|loved|at|called|named|to|visit|went to|go to|check out|book)\s+([A-Z][a-zA-Z'&-]+(?:\s[A-Z][a-zA-Z'&-]+){0,2})\b"#, group: 1, caseSensitive: true) {
                let lower = m.lowercased()
                guard !Self.commonWords.contains(lower), !context.knownPeople.contains(where: { $0.allNames.contains(lower) }) else { continue }
                guard lower != speaker.name?.lowercased() else { continue }
                out.places.append(m)
                out.people.removeAll { $0.lowercased() == lower }
                break
            }
        }
        out.organizations = taggedOrgs
        // A place never doubles as a person.
        out.people.removeAll { p in out.places.contains { $0.lowercased() == p.lowercased() } || Self.knownDestinations.contains(p.lowercased()) }
        out.people = uniqueCaseInsensitive(out.people)
        out.places = uniqueCaseInsensitive(out.places)
        return out
    }

    func isPlausiblePersonName(_ name: String) -> Bool {
        let words = name.split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 3, name.count <= 40 else { return false }
        guard words.allSatisfy({ $0.first?.isUppercase == true && $0.count >= 2 }) else { return false }
        if Self.commonWords.contains(name.lowercased()) || Self.commonWords.contains(words[0].lowercased()) { return false }
        if Self.knownDestinations.contains(name.lowercased()) { return false }
        if ProductRecognizer.brands.contains(name.lowercased()) { return false }
        return true
    }

    func canonicalPersonName(_ name: String) -> String {
        let lower = name.lowercased()
        if let id = context.personCorrections[lower], let p = context.knownPeople.first(where: { $0.id == id }) { return p.displayName }
        if let p = context.knownPeople.first(where: { $0.allNames.contains(lower) }) { return p.displayName }
        // "Rahul Sharma" → known "Rahul"? Only if first name uniquely matches.
        let first = lower.split(separator: " ").first.map(String.init) ?? lower
        let firstMatches = context.knownPeople.filter { $0.displayName.lowercased() == first || $0.displayName.lowercased().hasPrefix(first + " ") }
        if firstMatches.count == 1, name.contains(" ") { return firstMatches[0].displayName }
        return name.trimmed
    }

    private func isPersonNameConflict(_ place: String, people: [String]) -> Bool {
        people.contains { $0.lowercased() == place.lowercased() }
    }

    private func uniqueCaseInsensitive(_ list: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for item in list {
            let k = item.lowercased().trimmed
            if !k.isEmpty, !seen.contains(k) { seen.insert(k); out.append(item.trimmed) }
        }
        return out
    }

    /// Best guess at what kind of place this is from surrounding words.
    static func placeKind(for text: String) -> String {
        for (kind, pattern) in placeKindKeywords where text.matches(pattern) { return kind }
        return "unknown"
    }
}

/// Objects people want: "these New Balance shoes", "the Sony headphones", a product URL.
enum ProductRecognizer {
    static let brands: Set<String> = ["new balance", "nike", "adidas", "puma", "asics", "hoka", "on", "converse", "vans", "apple", "sony", "bose", "samsung", "dyson", "lego", "zara", "h&m", "uniqlo", "levi's", "levis", "ray-ban", "rayban", "casio", "seiko", "fossil", "titan", "kindle", "nintendo", "playstation", "xbox", "airpods", "ipad", "iphone", "macbook", "garmin", "fitbit", "oura", "lululemon", "patagonia", "north face", "the north face", "columbia", "birkenstock", "crocs", "skechers", "reebok", "jordan", "yeezy", "gucci", "prada", "coach", "michael kors", "kate spade", "fjallraven", "herschel", "moleskine", "lamy", "muji", "ikea", "le creuset", "stanley", "hydro flask", "yeti", "jbl", "marshall", "sennheiser", "logitech", "keychron", "canon", "nikon", "fujifilm", "gopro", "dji", "polaroid", "instax", "kindle"]

    static let productNouns: [String] = ["shoes", "sneakers", "trainers", "boots", "sandals", "heels", "watch", "smartwatch", "bag", "backpack", "tote", "purse", "wallet", "phone", "headphones", "earbuds", "earphones", "speaker", "laptop", "tablet", "camera", "lens", "book", "novel", "jacket", "coat", "hoodie", "sweater", "dress", "shirt", "t-shirt", "tee", "jeans", "perfume", "cologne", "fragrance", "ring", "necklace", "bracelet", "earrings", "sunglasses", "glasses", "keyboard", "mouse", "monitor", "console", "game", "lego", "plant", "candle", "mug", "bottle", "kettle", "blender", "mixer", "pan", "knife", "bike", "bicycle", "cycle", "skateboard", "guitar", "keyboard", "vinyl", "record player", "turntable", "kindle", "ipad", "iphone", "airpods", "macbook", "playstation", "xbox", "switch", "drone", "tent", "yoga mat", "dumbbells", "jersey", "scarf", "hat", "cap", "socks", "slippers", "pyjamas", "pajamas", "set", "kit", "case", "cover", "charger", "stand", "lamp", "chair", "desk", "rug", "poster", "print", "frame", "diffuser", "skincare", "serum", "lipstick", "makeup", "palette", "brush", "razor", "trimmer", "chocolate", "chocolates", "tea", "coffee beans", "wine", "whisky", "whiskey", "gin", "voucher", "gift card", "ticket", "tickets", "subscription", "course"]

    /// Extracts the object of a desire clause, e.g. "I really want these New Balance shoes so bad" → "New Balance shoes".
    static func object(afterDesireIn text: String) -> String? {
        let pattern = #"\b(?:want|wants|wanted|need|needs|love|loves|loved|like|likes|liked|wish(?:ed)? (?:i|she|he|they) had|would love|would like|eyeing|craving|dying for|dreaming of|been wanting|on my wishlist:?|wishlist:?)\s+(?:to (?:get|buy|have|own)\s+)?(?:these|those|this|that|a|an|the|some|one of these|one of those|a pair of|the new)?\s*([^.!?,;\n]{2,80})"#
        guard var obj = text.firstMatch(pattern, group: 1) else { return nil }
        obj = obj.replacingOccurrences(of: #"\s+(so bad(ly)?|so much|for (my|her|his|their) birthday|for christmas|for diwali|right now|honestly|tbh|lol|haha|😂|🥺|😍|❤️|please|pls|plz|omg)\b.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        obj = obj.strippingEmoji.trimmed
        obj = obj.replacingOccurrences(of: #"\s+(and|but|because|since|though|tho|when|if|so)\b.*$"#, with: "", options: [.regularExpression, .caseInsensitive]).trimmed
        guard obj.count >= 2 else { return nil }
        // Reject if the "object" is a verb phrase ("to go to Goa") or a person.
        if obj.lowercased().hasPrefix("to ") || obj.lowercased().hasPrefix("go ") { return nil }
        return obj
    }

    /// Does the clause name something purchasable?
    static func looksLikeProduct(_ text: String) -> Bool {
        let lower = text.lowercased()
        if brands.contains(where: { lower.containsWord($0) }) { return true }
        if productNouns.contains(where: { lower.containsWord($0) }) { return true }
        return false
    }

    static func productFromURL(_ url: URL) -> String? {
        let shoppingHosts = ["amazon", "flipkart", "myntra", "ajio", "nike", "newbalance", "adidas", "apple", "etsy", "zara", "hm.com", "uniqlo", "ebay", "walmart", "target", "bestbuy", "nykaa", "tatacliq", "shop", "store"]
        guard let host = url.host()?.lowercased(), shoppingHosts.contains(where: { host.contains($0) }) else { return nil }
        let slug = url.pathComponents.filter { $0.count > 3 && !$0.matches(#"^[A-Z0-9]{8,}$"#) && !$0.matches(#"^\d+$"#) }.last ?? ""
        let words = slug.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".html", with: "")
        let cleaned = words.split(separator: " ").map(String.init).filter { !$0.matches(#"^[a-z0-9]{10,}$"#) }.map { $0.capitalized }.joined(separator: " ")
        return cleaned.isEmpty ? host : cleaned
    }
}
