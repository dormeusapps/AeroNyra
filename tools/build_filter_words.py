#!/usr/bin/env python3
"""
build_filter_words.py — builds the content filter's bundled word files.

Inputs: the LDNOOBW `en` and `fr` files and LICENSE (CC BY 4.0) at the pinned
commit below, downloaded into a directory given as the only argument:

  B=https://raw.githubusercontent.com/LDNOOBW/List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words/5faf2ba42d7b1c0977169ec3611df25a3c08eb13
  curl -sfL $B/en -o <dir>/en; curl -sfL $B/fr -o <dir>/fr; curl -sfL $B/LICENSE -o <dir>/LICENSE
  python3 tools/build_filter_words.py <dir>

Outputs (in Beacon/, bundled with the app):
  filter-words-en.txt, filter-words-fr.txt  — upstream MINUS the exclusions below,
                                              every exclusion listed in the header
  filter-words-slurs.txt                    — our supplement (not from LDNOOBW)
  FILTER_WORDS_LICENSE.txt                  — attribution + the CC BY 4.0 text

Principle (Rubins, 2026-09-30): block profanity, slurs and explicit sexual
slang; allow clinical/medical, everyday and multi-meaning words, names,
titles, and phrases that match ordinary sentences.
"""
import hashlib, os, sys

UPSTREAM = "https://github.com/LDNOOBW/List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words"
COMMIT = "5faf2ba42d7b1c0977169ec3611df25a3c08eb13"
COMMIT_DATE = "2020-07-13"
EN_SHA256 = "af851ecef1d5f212caba17339b12ac39cc2fef7d78c74876f67237644fcee8bd"

EN_EXCLUDED = [
    # everyday / clinical (first ruling)
    "anal", "nude", "sex",
    # body / clinical
    "anus", "butt", "clitoris", "genitals", "nipple", "nipples", "penis", "pubes", "rectum",
    "semen", "vagina", "vulva", "snatch", "bung hole", "bunghole", "big breasts",
    # medical / clinical / legal (victims must be able to describe abuse)
    "ejaculation", "eunuch", "fecal", "intercourse", "masturbate", "masturbating",
    "masturbation", "orgasm", "sexual", "sexually", "sexuality", "sodomy", "sodomize",
    "incest", "nudity", "rape", "raping", "rapist", "date rape", "paedophile", "pedophile",
    "spastic", "urophilia", "coprophilia", "coprolagnia", "zoophilia", "acrotomophilia",
    "dendrophilia", "nymphomania", "nimphomania", "cialis", "viagra",
    # everyday / multi-meaning
    "xx", "xxx", "suck", "sucks", "escort", "hooker", "scat", "skeet", "horny", "sexy",
    "erotic", "homoerotic", "lovemaking", "topless", "undressing", "panties", "panty",
    "vibrator", "swinger", "voyeur", "threesome", "grope", "humping", "domination", "sadism",
    "bondage", "kinky", "twinkie", "snowballing", "negro", "mong", "nsfw", "smut",
    "hardcore", "hard core",
    # phrases that match ordinary sentences
    "big black", "girl on", "tied up", "taste my", "tongue in a", "tight white", "hot chick",
    "huge fat", "how to kill", "how to murder", "spread legs", "strip club", "god damn",
    "jelly donut", "tainted love", "dirty pillows", "deep throat", "missionary position",
    "baby juice", "leather restraint",
    # names / titles / genres / other languages
    "santorum", "octopussy", "lolita", "playboy", "babeland", "ecchi", "yaoi", "shota",
    "swastika", "neonazi", "bastardo", "sexo", "nutten",
]

FR_EXCLUDED = [
    # everyday / multi-meaning (first ruling)
    "bite", "con", "bourré", "bourrée", "folle", "gueule", "meuf", "pipi", "caca", "péter",
    "gerber",
    # body
    "clitoris", "cul", "zizi", "zigounette",
    # everyday
    "bordel", "jouir", "baiser", "foutre", "déconne", "déconner", "emmerdant", "emmerder",
    "emmerdeur", "emmerdeuse", "gerbe", "pédale", "tapette", "tanche", "ramoner", "suce",
    "turlute", "trique",
    # "negro" was ruled allowed (English everyday group); the same word is also in fr
    "negro",
]

SLURS = [
    # English — racial and ethnic
    "gook", "chink", "zipperhead", "sandnigger", "camel jockey", "porch monkey",
    "jungle bunny", "pickaninny", "golliwog", "wog", "dago", "wop", "kyke", "hymie",
    "halfbreed", "negress", "jap", "yid", "kraut", "polack", "chinaman", "coolie", "squaw",
    "redskin", "gyppo",
    # English — homophobic / transphobic
    "dyke", "ladyboy",
    # English — ableist
    "retard", "retarded", "mongoloid", "spaz",
    # French
    "bougnoule", "bicot", "youpin", "youtre", "bamboula", "chinetoque", "niakoué", "tarlouze",
    "triso", "gogol",
]


def read_terms(path):
    with open(path, encoding="utf-8") as f:
        return [line.strip() for line in f if line.strip()]


def filtered(terms, excluded, name):
    missing = [e for e in excluded if e not in terms]
    assert not missing, f"{name}: exclusions not in upstream: {missing}"
    return [t for t in terms if t not in excluded]


def header(title, source_file, excluded, kept):
    lines = [
        f"# AeroNyra content filter — {title}.",
        f"# Source: LDNOOBW \"List of Dirty, Naughty, Obscene, and Otherwise Bad Words\", file `{source_file}`,",
        f"#   {UPSTREAM}",
        f"#   commit {COMMIT} ({COMMIT_DATE}).",
        "# License: CC BY 4.0 — see FILTER_WORDS_LICENSE.txt. Modified: the terms listed below",
        "#   were REMOVED (ruled 2026-09-30: allow clinical/medical, everyday and multi-meaning",
        "#   words, names, titles, and phrases that match ordinary sentences).",
        "# Generated by tools/build_filter_words.py — do not edit by hand.",
        f"# Terms: {kept}. Excluded ({len(excluded)}):",
    ]
    lines += [f"#   {e}" for e in excluded]
    return "\n".join(lines) + "\n"


def main():
    src = sys.argv[1]
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Beacon")
    with open(os.path.join(src, "en"), "rb") as f:
        assert hashlib.sha256(f.read()).hexdigest() == EN_SHA256, "en is not the pinned upstream file"

    en = filtered(read_terms(os.path.join(src, "en")), EN_EXCLUDED, "en")
    fr = filtered(read_terms(os.path.join(src, "fr")), FR_EXCLUDED, "fr")

    with open(os.path.join(root, "filter-words-en.txt"), "w", encoding="utf-8") as f:
        f.write(header("English word list", "en", EN_EXCLUDED, len(en)) + "\n".join(en) + "\n")
    with open(os.path.join(root, "filter-words-fr.txt"), "w", encoding="utf-8") as f:
        f.write(header("French word list", "fr", FR_EXCLUDED, len(fr)) + "\n".join(fr) + "\n")
    with open(os.path.join(root, "filter-words-slurs.txt"), "w", encoding="utf-8") as f:
        f.write("# AeroNyra content filter — slurs supplement (English and French).\n"
                "# Not from LDNOOBW: slurs that list lacks, approved term by term by Rubins, 2026-09-30.\n"
                "# Generated by tools/build_filter_words.py — do not edit by hand.\n"
                f"# Terms: {len(SLURS)}.\n" + "\n".join(SLURS) + "\n")
    with open(os.path.join(src, "LICENSE"), encoding="utf-8") as f:
        license_text = f.read()
    with open(os.path.join(root, "FILTER_WORDS_LICENSE.txt"), "w", encoding="utf-8") as f:
        f.write("AeroNyra's content filter word lists (filter-words-en.txt, filter-words-fr.txt)\n"
                "are adapted from \"List of Dirty, Naughty, Obscene, and Otherwise Bad Words\"\n"
                f"(LDNOOBW), {UPSTREAM},\ncommit {COMMIT}, licensed under the Creative Commons\n"
                "Attribution 4.0 International License (CC BY 4.0). Changes: some terms were\n"
                "removed; each removal is listed in the header of the file it was removed from.\n"
                "filter-words-slurs.txt is AeroNyra's own supplement.\n\n"
                "The license text follows.\n\n" + license_text)
    print(f"en {len(en)}  fr {len(fr)}  slurs {len(SLURS)}")


if __name__ == "__main__":
    main()
