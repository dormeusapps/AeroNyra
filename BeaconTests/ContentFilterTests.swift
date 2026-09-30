//
//  ContentFilterTests.swift
//  BeaconTests
//
//  Pins the content filter's library and matching: the bundled files are in
//  the app, every term in them is caught, every ruled exclusion passes, whole
//  words only (innocent words containing a bad word pass), folding and
//  substitutions, the user's own words, and the ON/OFF switch.
//

import XCTest
@testable import Beacon

@MainActor
final class ContentFilterTests: XCTestCase {

    private let matcher = ContentFilterMatcher(userWords: "")

    private func caught(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(matcher.matches(text), "should be caught: \(text)", file: file, line: line)
    }

    private func passes(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(matcher.matches(text), "should pass: \(text)", file: file, line: line)
    }

    // MARK: - Library

    func testBundledFilesAreInTheApp() throws {
        for name in ContentFilterLibrary.resourceNames {
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: "txt"), name)
        }
        XCTAssertNotNil(Bundle.main.url(forResource: "FILTER_WORDS_LICENSE", withExtension: "txt"))
        let terms = ContentFilterLibrary.bundledTerms()
        XCTAssertEqual(terms.count, 284 + 57 + 41)
        XCTAssertFalse(terms.contains { $0.hasPrefix("#") })
    }

    func testEveryBundledTermIsCaught() {
        for term in ContentFilterLibrary.bundledTerms() {
            caught("well \(term) then")
        }
    }

    /// The ruling of 2026-09-30: these are let through.
    static let excluded = [
        "anal", "nude", "sex", "anus", "butt", "clitoris", "genitals", "nipple", "nipples",
        "penis", "pubes", "rectum", "semen", "vagina", "vulva", "snatch", "bung hole", "bunghole",
        "big breasts", "ejaculation", "eunuch", "fecal", "intercourse", "masturbate",
        "masturbating", "masturbation", "orgasm", "sexual", "sexually", "sexuality", "sodomy",
        "sodomize", "incest", "nudity", "rape", "raping", "rapist", "date rape", "paedophile",
        "pedophile", "spastic", "urophilia", "coprophilia", "coprolagnia", "zoophilia",
        "acrotomophilia", "dendrophilia", "nymphomania", "nimphomania", "cialis", "viagra",
        "xx", "xxx", "suck", "sucks", "escort", "hooker", "scat", "skeet", "horny", "sexy",
        "erotic", "homoerotic", "lovemaking", "topless", "undressing", "panties", "panty",
        "vibrator", "swinger", "voyeur", "threesome", "grope", "humping", "domination", "sadism",
        "bondage", "kinky", "twinkie", "snowballing", "negro", "mong", "nsfw", "smut", "hardcore",
        "hard core", "big black", "girl on", "tied up", "taste my", "tongue in a", "tight white",
        "hot chick", "huge fat", "how to kill", "how to murder", "spread legs", "strip club",
        "god damn", "jelly donut", "tainted love", "dirty pillows", "deep throat",
        "missionary position", "baby juice", "leather restraint", "santorum", "octopussy",
        "lolita", "playboy", "babeland", "ecchi", "yaoi", "shota", "swastika", "neonazi",
        "bastardo", "sexo", "nutten",
        "bite", "con", "bourré", "bourrée", "folle", "gueule", "meuf", "pipi", "caca", "péter",
        "gerber", "cul", "zizi", "zigounette", "bordel", "jouir", "baiser", "foutre", "déconne",
        "déconner", "emmerdant", "emmerder", "emmerdeur", "emmerdeuse", "gerbe", "pédale",
        "tapette", "tanche", "ramoner", "suce", "turlute", "trique",
        "nip", "spook", "kafir", "kaffir",
    ]

    func testEveryExclusionPasses() {
        for term in Self.excluded {
            passes("well \(term) then")
        }
    }

    // MARK: - Named cases (ruling)

    func testNamedCasesPass() {
        passes("this sucks")
        passes("turn into the cul-de-sac")
        passes("see you soon xx")
        passes("she reported the rape to the police")
    }

    func testNamedCasesAreCaught() {
        caught("oh merde")
        caught("putain, encore")
        caught("what a bitch")
        caught("🖕")
        caught("ok 🖕🏽")
        caught("you gook")
    }

    // MARK: - Whole words only

    func testInnocentWordsPass() {
        for text in ["Scunthorpe", "an assassin", "a classic", "Essex", "the cockpit",
                     "my therapist", "shiitake", "Dickens", "a peacock", "grape juice",
                     "Room 455", "she passes", "Hancock", "cocktail", "button", "analysis",
                     "therapists", "a shitake typo"] {
            passes(text)
        }
    }

    // MARK: - Folding and substitutions

    func testFoldingAndSubstitutionsAreCaught() {
        for text in ["FUCK", "Fück", "ｆｕｃｋ", "f*ck", "f**k", "f.u.c.k", "f u c k", "fuuuuck",
                     "sh1t", "$hit", "b!tch", "a55", "fils-de-pute", "Fils De Pute", "ENCULÉ",
                     "enculé", "bitches", "shits", "c0ck"] {
            caught(text)
        }
    }

    func testPlainTextAndEmptyPass() {
        passes("")
        passes("see you at 7")
        passes("***")
        passes("a b c")
    }

    // MARK: - User words

    func testUserWordsAreAddedOnTop() {
        let m = ContentFilterMatcher(userWords: " pineapple , , Crème brûlée,")
        XCTAssertTrue(m.matches("I love PINEAPPLE"))
        XCTAssertTrue(m.matches("pineapples again"))
        XCTAssertTrue(m.matches("creme brulee tonight"))
        XCTAssertFalse(m.matches("creme tonight"))
        XCTAssertTrue(m.matches("fuck"))          // the library still applies
        XCTAssertFalse(matcher.matches("pineapple"))
    }

    // MARK: - The switch

    func testOffPassesEverythingOnBlocks() {
        let name = "content-filter-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }

        XCTAssertTrue(ContentFilter.isEnabled(defaults))             // default ON
        XCTAssertTrue(ContentFilter.blocks("fuck", defaults: defaults))
        defaults.set("pineapple", forKey: ContentFilter.wordsKey)
        XCTAssertTrue(ContentFilter.blocks("pineapple", defaults: defaults))

        defaults.set(false, forKey: ContentFilter.enabledKey)
        XCTAssertFalse(ContentFilter.blocks("fuck", defaults: defaults))
        XCTAssertFalse(ContentFilter.blocks("pineapple", defaults: defaults))
        XCTAssertFalse(ContentFilter.blocks("🖕", defaults: defaults))
    }
}
