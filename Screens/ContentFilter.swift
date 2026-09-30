//
//  ContentFilter.swift
//  Screens
//
//  Local, on-device content filter (App Review Guideline 1.2). Text only.
//  The word library is bundled (built by tools/build_filter_words.py):
//   • filter-words-en.txt, filter-words-fr.txt — LDNOOBW, CC BY 4.0, with the
//     exclusions ruled 2026-09-30 removed (each listed in the file header);
//   • filter-words-slurs.txt — our supplement.
//  Attribution: FILTER_WORDS_LICENSE.txt and the Content filter screen.
//  The user's own words (comma-separated, Settings) are added on top; the
//  library itself is not editable.
//
//  MATCHING — whole words only, never substrings ("classic" passes "ass").
//  The text and every term are folded the same way: case, accents and width
//  ("Fück" → "fuck"). Each word of the text is then also tried with common
//  substitutions (0→o, 1→i or l, 3→e, 4/@→a, 5/$→s, 7→t, !→i), with a "*"
//  standing for any one letter, and with runs of three or more of the same
//  letter squeezed to two or one ("fuuuck"). Three or more single letters in
//  a row are also tried joined ("f.u.c.k", "f u c k"). A trailing s, es or x
//  (plurals) still matches. Multi-word terms match as consecutive words.
//  Terms with no letters or digits (🖕) match anywhere in the raw text.
//  Substitutions only apply to words that contain a letter, so "455" stays
//  a number.
//
//  Storage is `@AppStorage` (UserDefaults): `enabledKey` (default ON) and
//  `wordsKey`. Both are cleared on crypto-erase by `DeviceResidueWipe`: a
//  user-authored word list is fingerprinting residue.
//

import Foundation

/// A set of filter terms, split into single words, phrases and symbols.
struct ContentFilterLibrary: Sendable {

    let words: Set<String>
    let phrases: [[String]]
    let symbols: [String]

    init(terms: [String]) {
        var words = Set<String>()
        var phrases: [[String]] = []
        var symbols: [String] = []
        for term in terms {
            let tokens = ContentFilterText.termTokens(term)
            switch tokens.count {
            case 0:
                let raw = term.trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty { symbols.append(raw) }
            case 1:
                words.insert(tokens[0])
            default:
                phrases.append(tokens)
            }
        }
        self.words = words
        self.phrases = phrases
        self.symbols = symbols
    }

    var isEmpty: Bool { words.isEmpty && phrases.isEmpty && symbols.isEmpty }

    /// The bundled word files, in the app bundle.
    static let resourceNames = ["filter-words-en", "filter-words-fr", "filter-words-slurs"]

    /// Terms from one word file: one per line; blank lines and `#` comments skipped.
    static func terms(fromFile text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Every term in the bundled files. A missing file contributes nothing
    /// (ContentFilterTests fails if any is missing from the app bundle).
    static func bundledTerms(in bundle: Bundle = .main) -> [String] {
        resourceNames.flatMap { name -> [String] in
            guard let url = bundle.url(forResource: name, withExtension: "txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return terms(fromFile: text)
        }
    }

    /// Loaded once, on first use.
    static let bundled = ContentFilterLibrary(terms: bundledTerms())
}

/// Folding and tokenising shared by terms and text.
enum ContentFilterText {

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
    }

    /// A term's words: folded, split on anything that is not a letter or digit.
    static func termTokens(_ term: String) -> [String] {
        fold(term).split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// Substitution characters kept inside a text word so they can be mapped.
    private static let substitutionChars: Set<Character> = ["@", "$", "!", "*"]

    /// A text's words: folded, split on anything that is not a letter, digit
    /// or substitution character.
    static func textTokens(_ text: String) -> [String] {
        fold(text).split { !($0.isLetter || $0.isNumber || substitutionChars.contains($0)) }
            .map(String.init)
    }

    private static func substituted(_ token: String, one: Character) -> String {
        String(token.map { c -> Character in
            switch c {
            case "0": return "o"
            case "1": return one
            case "3": return "e"
            case "4", "@": return "a"
            case "5", "$": return "s"
            case "7": return "t"
            case "!": return "i"
            default: return c
            }
        })
    }

    /// Runs of three or more of the same character squeezed to `keep`.
    private static func squeezed(_ s: String, keep: Int) -> String {
        var out = ""
        var last: Character?
        var run = 0
        for c in s {
            if c == last { run += 1 } else { last = c; run = 1 }
            if run <= keep { out.append(c) }
        }
        return out
    }

    /// Every form of one text word to look up.
    static func candidates(_ token: String) -> Set<String> {
        var forms: Set<String> = [String(token.filter { $0.isLetter || $0.isNumber })]
        if token.contains(where: \.isLetter) {
            forms.insert(substituted(token, one: "i"))
            forms.insert(substituted(token, one: "l"))
        }
        for form in forms where form.count >= 3 {
            forms.insert(squeezed(form, keep: 2))
            forms.insert(squeezed(form, keep: 1))
        }
        forms.remove("")
        return forms
    }
}

/// The library plus the user's own words, applied to one text.
struct ContentFilterMatcher: Sendable {

    let libraries: [ContentFilterLibrary]

    init(library: ContentFilterLibrary = .bundled, userWords: String) {
        let user = ContentFilterLibrary(terms: userWords.split(separator: ",").map(String.init))
        self.libraries = user.isEmpty ? [library] : [library, user]
    }

    func matches(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        for library in libraries {
            for symbol in library.symbols
            where (text as NSString).range(of: symbol, options: .literal).location != NSNotFound {
                return true
            }
        }
        let tokens = ContentFilterText.textTokens(text)
        guard !tokens.isEmpty else { return false }
        let forms = tokens.map(ContentFilterText.candidates)

        // Single words, including three or more single letters in a row joined.
        var wordForms = forms
        var run: [String] = []
        for token in tokens + [""] {
            if token.count == 1 {
                run.append(token)
            } else {
                if run.count >= 3 { wordForms.append(ContentFilterText.candidates(run.joined())) }
                run = []
            }
        }
        for library in libraries {
            for set in wordForms where set.contains(where: { isWord($0, in: library) }) {
                return true
            }
            for phrase in library.phrases where phrase.count <= tokens.count {
                for start in 0...(tokens.count - phrase.count)
                where phrase.indices.allSatisfy({ j in
                    let set = forms[start + j]
                    return j == phrase.count - 1
                        ? set.contains { $0 == phrase[j] || stems(of: $0).contains(phrase[j]) }
                        : set.contains(phrase[j])
                }) {
                    return true
                }
            }
        }
        return false
    }

    /// The form itself or its singular is in the library; a "*" in the form
    /// matches any one character of a same-length library word.
    private func isWord(_ form: String, in library: ContentFilterLibrary) -> Bool {
        if form.contains("*") {
            guard form.contains(where: \.isLetter) else { return false }
            let pattern = Array(form)
            return library.words.contains { word in
                word.count == pattern.count
                    && zip(word, pattern).allSatisfy { $1 == "*" || $0 == $1 }
            }
        }
        return library.words.contains(form) || stems(of: form).contains { library.words.contains($0) }
    }

    /// Plural stems: drop a trailing s or x, or es.
    private func stems(of form: String) -> [String] {
        var out: [String] = []
        if form.count > 2, form.hasSuffix("s") || form.hasSuffix("x") { out.append(String(form.dropLast())) }
        if form.count > 3, form.hasSuffix("es") { out.append(String(form.dropLast(2))) }
        return out
    }
}

/// The app-wide filter: the setting, the user's words and the bundled library.
@MainActor
enum ContentFilter {

    static let enabledKey = "aeronyra.contentFilter.enabled.v1"
    static let wordsKey = "aeronyra.contentFilter.words.v1"

    /// ON unless the user turned it off.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// True when `text` contains a filtered word (library or user word).
    /// Ignores the setting — see `blocks`.
    static func matches(_ text: String, userWords: String) -> Bool {
        matcher(for: userWords).matches(text)
    }

    /// True when the filter is ON and `text` contains a filtered word.
    static func blocks(_ text: String, defaults: UserDefaults = .standard) -> Bool {
        isEnabled(defaults) && matches(text, userWords: defaults.string(forKey: wordsKey) ?? "")
    }

    // One matcher per distinct user-word string (the library is fixed).
    private static var cachedUserWords: String?
    private static var cachedMatcher: ContentFilterMatcher?

    private static func matcher(for userWords: String) -> ContentFilterMatcher {
        if userWords == cachedUserWords, let cachedMatcher { return cachedMatcher }
        let matcher = ContentFilterMatcher(userWords: userWords)
        cachedUserWords = userWords
        cachedMatcher = matcher
        return matcher
    }
}
