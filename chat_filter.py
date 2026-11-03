"""
The trade-room chat filter: swearing, slurs and sexual words are starred out before the
other trainer sees them (friends.trade_chat). The admin page still gets the original line,
marked as filtered (trade_chats.py), so a report shows what was really typed.

Words are matched after undoing the usual tricks: case, leetspeak (sh1t, @ss, $hit),
stretched letters (fuuuuck), and dots / dashes / spaces between letters (f.u.c.k, f u c k).
WORDS match a whole word and its endings (fuck -> fucking, fucker); STEMS match anywhere inside
a word too, so only stems that are (nearly) never part of an innocent word go there.
"""
import re

# Whole words (and their -s/-ed/-er/-ing/-y forms).
WORDS = {
    "fuck", "fuk", "fck", "fuq", "shit", "sht", "bitch", "biatch", "bastard", "cunt", "dick", "dik",
    "cock", "pussy", "puss", "asshole", "ass", "arse", "arsehole", "twat", "wanker", "wank", "prick",
    "slut", "whore", "hoe", "bollocks", "bellend", "knob", "douche", "douchebag", "motherfucker",
    "mf", "mfer", "stfu", "gtfo", "wtf", "kys", "dumbass", "jackass", "dipshit", "bullshit", "crap",
    "piss", "cum", "jizz", "boob", "boobs", "tits", "titty", "porn", "porno", "sex", "sexy", "horny",
    "nude", "nudes", "naked", "dildo", "anal", "penis", "vagina", "rape", "rapist", "molest", "pedo",
    "pedophile", "paedo", "nazi", "hitler", "retard", "retarded", "tard", "spaz", "autist",
    "fag", "faggot", "dyke", "tranny", "homo", "queer",
    "nigger", "nigga", "nigg", "negro", "chink", "gook", "spic", "wetback", "kike", "beaner",
    "coon", "paki", "raghead", "towelhead", "gypsy", "jap",
    "killyourself", "kill yourself", "go die", "neck yourself",
}
# Anywhere inside a word as well.
# (Not "nigg"/"nigger": sniggering. Not "cunt": Scunthorpe. Not "rapist": therapist. Not "kys": skyscraper.)
STEMS = {"fuck", "fuk", "shit", "bitch", "nigga", "faggot", "whore", "slut",
         "motherf", "dickhead", "cocksuck", "asshole", "jizz", "porn", "pedophil"}

_LEET = str.maketrans({"0": "o", "1": "i", "!": "i", "|": "i", "3": "e", "4": "a", "@": "a",
                       "5": "s", "$": "s", "7": "t", "+": "t", "8": "b", "9": "g", "€": "e",
                       "¡": "i", "ß": "ss"})
_ENDINGS = ("", "s", "es", "ed", "er", "ers", "ing", "in", "y", "z", "head", "face", "hole")
_SEP = re.compile(r"[\s.\-_*,'~^]+")


def _norm(s):
    """Lower case, leetspeak undone, a letter repeated 3+ times squeezed to one."""
    s = s.lower().translate(_LEET)
    s = re.sub(r"(.)\1{2,}", r"\1", s)
    return s


def _squeeze(s):
    """Also catch doubled letters (fuuck -> fuck, shiit -> shit)."""
    return re.sub(r"(.)\1+", r"\1", s)


def _bad_word(w):
    if not w:
        return False
    for form in {w, _squeeze(w)}:
        for end in _ENDINGS:
            if end and form.endswith(end) and form[:-len(end)] in WORDS:
                return True
        if form in WORDS:
            return True
    return any(stem in w for stem in STEMS)          # not on the squeezed form: shiitake -> shitake


_SPACED = re.compile(r"(?<![\w@$])(?:[\w@$!|][\s.\-_*,~^]+){2,}[\w@$!|](?![\w@$])")
_PHRASES = ("killyourself", "kilyourself", "neckyourself", "killurself", "kilurself")
_GO_DIE = re.compile(r"\bgo\W*(?:and\W*)?die\b")


def clean(text):
    """-> (the text to show, whether anything was starred out)."""
    hit = False

    def spaced(m):                              # f u c k, f.u.c.k: single letters split up
        nonlocal hit
        run = m.group(0)
        if _bad_word(_SEP.sub("", _norm(run))):
            hit = True
            return re.sub(r"[^\s]", "*", run)
        return run

    def star(m):
        nonlocal hit
        word = m.group(0)
        if set(word) == {"*"}:
            return word
        if _bad_word(_norm(word).strip("_")):
            hit = True
            return word[0] + "*" * (len(word) - 1) if len(word) > 1 else "*"
        return word

    out = _SPACED.sub(spaced, text)
    out = re.sub(r"[\w@$!|+€¡*]+", star, out)
    if any(p in _SEP.sub("", _norm(text)) for p in _PHRASES) or _GO_DIE.search(_norm(text)):
        return "****", True                     # "kill yourself" and the like: the whole line goes
    return out, hit


if __name__ == "__main__":                       # python3 chat_filter.py "some text"
    import sys
    print(clean(" ".join(sys.argv[1:])))
