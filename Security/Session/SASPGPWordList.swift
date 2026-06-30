// SASPGPWordList.swift
// Security/Session
//
// The canonical PGP / PGPfone "biometric" word list — the real alphabet for the
// SAS phrase codec (SASWordPhrase.swift) used in closed-contact pairing
// (docs/CONTACT_MODEL.md §5). Two lists of 256 words each: the EVEN list is the
// two-syllable words (used at even phrase positions), the ODD list is the
// three-syllable words (used at odd positions). Designed in 1995 by Patrick
// Juola and Philip Zimmermann to be maximally distinct when read aloud over a
// voice channel — the same list ZRTP/PGPfone use.
//
// PROVENANCE + INTEGRITY: this data was extracted from a tested reference
// implementation (magic-wormhole's `_wordlist`) and machine-verified against
// published reference vectors before being embedded — see
// SASPGPWordListTests.swift, which pins the byte→word anchors (e.g. 0x00 →
// aardvark/adroitness, 0xE5 0x82 → "topmost Istanbul", 0x82 0xE5 → "miser
// travesty", 0xFF → Zulu/Yucatan). A widely-copied GitHub gist of this list was
// found to be CORRUPTED (it drops "aftermath" at odd[0x02], shifting the rest);
// the KAT test exists precisely to catch that class of silent error, so do NOT
// replace this data without re-running it.
//
// Generated from verified data — do not hand-edit individual words.
//

import Foundation

public extension SASWordList {
    /// The canonical PGP biometric word list. Force-try is safe: the embedded
    /// arrays are fixed, exactly 256 each, and duplicate-free, all enforced by
    /// SASPGPWordListTests; a failure here would be a build-time data defect.
    static let pgp: SASWordList = {
        // swiftlint:disable:next force_try
        try! SASWordList(even: pgpEvenWords, odd: pgpOddWords)
    }()
}

/// 256 two-syllable words, index = byte value (0x00…0xFF).
let pgpEvenWords: [String] = [
    "aardvark", "absurd", "accrue", "acme", "adrift", "adult",
    "afflict", "ahead", "aimless", "Algol", "allow", "alone",
    "ammo", "ancient", "apple", "artist", "assume", "Athens",
    "atlas", "Aztec", "baboon", "backfield", "backward", "banjo",
    "beaming", "bedlamp", "beehive", "beeswax", "befriend", "Belfast",
    "berserk", "billiard", "bison", "blackjack", "blockade", "blowtorch",
    "bluebird", "bombast", "bookshelf", "brackish", "breadline", "breakup",
    "brickyard", "briefcase", "Burbank", "button", "buzzard", "cement",
    "chairlift", "chatter", "checkup", "chisel", "choking", "chopper",
    "Christmas", "clamshell", "classic", "classroom", "cleanup", "clockwork",
    "cobra", "commence", "concert", "cowbell", "crackdown", "cranky",
    "crowfoot", "crucial", "crumpled", "crusade", "cubic", "dashboard",
    "deadbolt", "deckhand", "dogsled", "dragnet", "drainage", "dreadful",
    "drifter", "dropper", "drumbeat", "drunken", "Dupont", "dwelling",
    "eating", "edict", "egghead", "eightball", "endorse", "endow",
    "enlist", "erase", "escape", "exceed", "eyeglass", "eyetooth",
    "facial", "fallout", "flagpole", "flatfoot", "flytrap", "fracture",
    "framework", "freedom", "frighten", "gazelle", "Geiger", "glitter",
    "glucose", "goggles", "goldfish", "gremlin", "guidance", "hamlet",
    "highchair", "hockey", "indoors", "indulge", "inverse", "involve",
    "island", "jawbone", "keyboard", "kickoff", "kiwi", "klaxon",
    "locale", "lockup", "merit", "minnow", "miser", "Mohawk",
    "mural", "music", "necklace", "Neptune", "newborn", "nightbird",
    "Oakland", "obtuse", "offload", "optic", "orca", "payday",
    "peachy", "pheasant", "physique", "playhouse", "Pluto", "preclude",
    "prefer", "preshrunk", "printer", "prowler", "pupil", "puppy",
    "python", "quadrant", "quiver", "quota", "ragtime", "ratchet",
    "rebirth", "reform", "regain", "reindeer", "rematch", "repay",
    "retouch", "revenge", "reward", "rhythm", "ribcage", "ringbolt",
    "robust", "rocker", "ruffled", "sailboat", "sawdust", "scallion",
    "scenic", "scorecard", "Scotland", "seabird", "select", "sentence",
    "shadow", "shamrock", "showgirl", "skullcap", "skydive", "slingshot",
    "slowdown", "snapline", "snapshot", "snowcap", "snowslide", "solo",
    "southward", "soybean", "spaniel", "spearhead", "spellbind", "spheroid",
    "spigot", "spindle", "spyglass", "stagehand", "stagnate", "stairway",
    "standard", "stapler", "steamship", "sterling", "stockman", "stopwatch",
    "stormy", "sugar", "surmount", "suspense", "sweatband", "swelter",
    "tactics", "talon", "tapeworm", "tempest", "tiger", "tissue",
    "tonic", "topmost", "tracker", "transit", "trauma", "treadmill",
    "Trojan", "trouble", "tumor", "tunnel", "tycoon", "uncut",
    "unearth", "unwind", "uproot", "upset", "upshot", "vapor",
    "village", "virus", "Vulcan", "waffle", "wallet", "watchword",
    "wayside", "willow", "woodlark", "Zulu"
]

/// 256 three-syllable words, index = byte value (0x00…0xFF).
let pgpOddWords: [String] = [
    "adroitness", "adviser", "aftermath", "aggregate", "alkali", "almighty",
    "amulet", "amusement", "antenna", "applicant", "Apollo", "armistice",
    "article", "asteroid", "Atlantic", "atmosphere", "autopsy", "Babylon",
    "backwater", "barbecue", "belowground", "bifocals", "bodyguard", "bookseller",
    "borderline", "bottomless", "Bradbury", "bravado", "Brazilian", "breakaway",
    "Burlington", "businessman", "butterfat", "Camelot", "candidate", "cannonball",
    "Capricorn", "caravan", "caretaker", "celebrate", "cellulose", "certify",
    "chambermaid", "Cherokee", "Chicago", "clergyman", "coherence", "combustion",
    "commando", "company", "component", "concurrent", "confidence", "conformist",
    "congregate", "consensus", "consulting", "corporate", "corrosion", "councilman",
    "crossover", "crucifix", "cumbersome", "customer", "Dakota", "decadence",
    "December", "decimal", "designing", "detector", "detergent", "determine",
    "dictator", "dinosaur", "direction", "disable", "disbelief", "disruptive",
    "distortion", "document", "embezzle", "enchanting", "enrollment", "enterprise",
    "equation", "equipment", "escapade", "Eskimo", "everyday", "examine",
    "existence", "exodus", "fascinate", "filament", "finicky", "forever",
    "fortitude", "frequency", "gadgetry", "Galveston", "getaway", "glossary",
    "gossamer", "graduate", "gravity", "guitarist", "hamburger", "Hamilton",
    "handiwork", "hazardous", "headwaters", "hemisphere", "hesitate", "hideaway",
    "holiness", "hurricane", "hydraulic", "impartial", "impetus", "inception",
    "indigo", "inertia", "infancy", "inferno", "informant", "insincere",
    "insurgent", "integrate", "intention", "inventive", "Istanbul", "Jamaica",
    "Jupiter", "leprosy", "letterhead", "liberty", "maritime", "matchmaker",
    "maverick", "Medusa", "megaton", "microscope", "microwave", "midsummer",
    "millionaire", "miracle", "misnomer", "molasses", "molecule", "Montana",
    "monument", "mosquito", "narrative", "nebula", "newsletter", "Norwegian",
    "October", "Ohio", "onlooker", "opulent", "Orlando", "outfielder",
    "Pacific", "pandemic", "Pandora", "paperweight", "paragon", "paragraph",
    "paramount", "passenger", "pedigree", "Pegasus", "penetrate", "perceptive",
    "performance", "pharmacy", "phonetic", "photograph", "pioneer", "pocketful",
    "politeness", "positive", "potato", "processor", "provincial", "proximate",
    "puberty", "publisher", "pyramid", "quantity", "racketeer", "rebellion",
    "recipe", "recover", "repellent", "replica", "reproduce", "resistor",
    "responsive", "retraction", "retrieval", "retrospect", "revenue", "revival",
    "revolver", "sandalwood", "sardonic", "Saturday", "savagery", "scavenger",
    "sensation", "sociable", "souvenir", "specialist", "speculate", "stethoscope",
    "stupendous", "supportive", "surrender", "suspicious", "sympathy", "tambourine",
    "telephone", "therapist", "tobacco", "tolerance", "tomorrow", "torpedo",
    "tradition", "travesty", "trombonist", "truncated", "typewriter", "ultimate",
    "undaunted", "underfoot", "unicorn", "unify", "universe", "unravel",
    "upcoming", "vacancy", "vagabond", "vertigo", "Virginia", "visitor",
    "vocalist", "voyager", "warranty", "Waterloo", "whimsical", "Wichita",
    "Wilmington", "Wyoming", "yesteryear", "Yucatan"
]
