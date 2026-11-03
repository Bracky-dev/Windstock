"""Generation 2 (#152-251) species data for the 0.35 client.

Base stats are the main-series ones; GO's 2017 formulas turn them into attack / defense / stamina:
    attack  = round(2 * (7/8 * max(Atk, SpA) + 1/8 * min(Atk, SpA)) * (1 + (Spe - 75) / 500))
    defense = round(2 * (7/8 * max(Def, SpD) + 1/8 * min(Def, SpD)) * (1 + (Spe - 75) / 500))
    stamina = 2 * HP
(Checked against Chikorita's hand-entered 92 / 122 / 90.)  The 0.35 client only knows ids <= 151 in its enum; the
game binary is patched (Get_Pokemon skips Enum.IsDefined) and the template_id of each entry is the bare number.
"""
NORMAL, FIGHTING, FLYING, POISON, GROUND, ROCK, BUG, GHOST, STEEL, FIRE, WATER, GRASS, ELECTRIC, PSYCHIC, ICE, DRAGON, DARK, FAIRY = range(1, 19)

# id: (name, type1, type2, hp, atk, def, spa, spd, spe, height_m, weight_kg, evolves_to)
SPECIES = {
    152: ("Chikorita", GRASS, 0, 45, 49, 65, 49, 65, 45, 0.9, 6.4, [153]),
    153: ("Bayleef", GRASS, 0, 60, 62, 80, 63, 80, 60, 1.2, 15.8, [154]),
    154: ("Meganium", GRASS, 0, 80, 82, 100, 83, 100, 80, 1.8, 100.5, []),
    155: ("Cyndaquil", FIRE, 0, 39, 52, 43, 60, 50, 65, 0.5, 7.9, [156]),
    156: ("Quilava", FIRE, 0, 58, 64, 58, 80, 65, 80, 0.9, 19.0, [157]),
    157: ("Typhlosion", FIRE, 0, 78, 84, 78, 109, 85, 100, 1.7, 79.5, []),
    158: ("Totodile", WATER, 0, 50, 65, 64, 44, 48, 43, 0.6, 9.5, [159]),
    159: ("Croconaw", WATER, 0, 65, 80, 80, 59, 63, 58, 1.1, 25.0, [160]),
    160: ("Feraligatr", WATER, 0, 85, 105, 100, 79, 83, 78, 2.3, 88.8, []),
    161: ("Sentret", NORMAL, 0, 35, 46, 34, 35, 45, 20, 0.8, 6.0, [162]),
    162: ("Furret", NORMAL, 0, 85, 76, 64, 45, 55, 90, 1.8, 32.5, []),
    163: ("Hoothoot", NORMAL, FLYING, 60, 30, 30, 36, 56, 50, 0.7, 21.2, [164]),
    164: ("Noctowl", NORMAL, FLYING, 100, 50, 50, 76, 96, 70, 1.6, 40.8, []),
    165: ("Ledyba", BUG, FLYING, 40, 20, 30, 40, 80, 55, 1.0, 10.8, [166]),
    166: ("Ledian", BUG, FLYING, 55, 35, 50, 55, 110, 85, 1.4, 35.6, []),
    167: ("Spinarak", BUG, POISON, 40, 60, 40, 40, 40, 30, 0.5, 8.5, [168]),
    168: ("Ariados", BUG, POISON, 70, 90, 70, 60, 70, 40, 1.1, 33.5, []),
    169: ("Crobat", POISON, FLYING, 85, 90, 80, 70, 80, 130, 1.8, 75.0, []),
    170: ("Chinchou", WATER, ELECTRIC, 75, 38, 38, 56, 56, 67, 0.5, 12.0, [171]),
    171: ("Lanturn", WATER, ELECTRIC, 125, 58, 58, 76, 76, 67, 1.2, 22.5, []),
    172: ("Pichu", ELECTRIC, 0, 20, 40, 15, 35, 35, 60, 0.3, 2.0, [25]),
    173: ("Cleffa", FAIRY, 0, 50, 25, 28, 45, 55, 15, 0.3, 3.0, [35]),
    174: ("Igglybuff", NORMAL, FAIRY, 90, 30, 15, 40, 20, 15, 0.3, 1.0, [39]),
    175: ("Togepi", FAIRY, 0, 35, 20, 65, 40, 65, 20, 0.3, 1.5, [176]),
    176: ("Togetic", FAIRY, FLYING, 55, 40, 85, 80, 105, 40, 0.6, 3.2, []),
    177: ("Natu", PSYCHIC, FLYING, 40, 50, 45, 70, 45, 70, 0.2, 2.0, [178]),
    178: ("Xatu", PSYCHIC, FLYING, 65, 75, 70, 95, 70, 95, 1.5, 15.0, []),
    179: ("Mareep", ELECTRIC, 0, 55, 40, 40, 65, 45, 35, 0.6, 7.8, [180]),
    180: ("Flaaffy", ELECTRIC, 0, 70, 55, 55, 80, 60, 45, 0.8, 13.3, [181]),
    181: ("Ampharos", ELECTRIC, 0, 90, 75, 85, 115, 90, 55, 1.4, 61.5, []),
    182: ("Bellossom", GRASS, 0, 75, 80, 95, 90, 100, 50, 0.4, 5.8, []),
    183: ("Marill", WATER, FAIRY, 70, 20, 50, 20, 50, 40, 0.4, 8.5, [184]),
    184: ("Azumarill", WATER, FAIRY, 100, 50, 80, 60, 80, 50, 0.8, 28.5, []),
    185: ("Sudowoodo", ROCK, 0, 70, 100, 115, 30, 65, 30, 1.2, 38.0, []),
    186: ("Politoed", WATER, 0, 90, 75, 75, 90, 100, 70, 1.1, 33.9, []),
    187: ("Hoppip", GRASS, FLYING, 35, 35, 40, 35, 55, 50, 0.4, 0.5, [188]),
    188: ("Skiploom", GRASS, FLYING, 55, 45, 50, 45, 65, 80, 0.6, 1.0, [189]),
    189: ("Jumpluff", GRASS, FLYING, 75, 55, 70, 55, 95, 110, 0.8, 3.0, []),
    190: ("Aipom", NORMAL, 0, 55, 70, 55, 40, 55, 85, 0.8, 11.5, []),
    191: ("Sunkern", GRASS, 0, 30, 30, 30, 30, 30, 30, 0.3, 1.8, [192]),
    192: ("Sunflora", GRASS, 0, 75, 75, 55, 105, 85, 30, 0.8, 8.5, []),
    193: ("Yanma", BUG, FLYING, 65, 65, 45, 75, 45, 95, 1.2, 38.0, []),
    194: ("Wooper", WATER, GROUND, 55, 45, 45, 25, 25, 15, 0.4, 8.5, [195]),
    195: ("Quagsire", WATER, GROUND, 95, 85, 85, 65, 65, 35, 1.4, 75.0, []),
    196: ("Espeon", PSYCHIC, 0, 65, 65, 60, 130, 95, 110, 0.9, 26.5, []),
    197: ("Umbreon", DARK, 0, 95, 65, 110, 60, 130, 65, 1.0, 27.0, []),
    198: ("Murkrow", DARK, FLYING, 60, 85, 42, 85, 42, 91, 0.5, 2.1, []),
    199: ("Slowking", WATER, PSYCHIC, 95, 75, 80, 100, 110, 30, 2.0, 79.5, []),
    200: ("Misdreavus", GHOST, 0, 60, 60, 60, 85, 85, 85, 0.7, 1.0, []),
    201: ("Unown", PSYCHIC, 0, 48, 72, 48, 72, 48, 48, 0.5, 5.0, []),
    202: ("Wobbuffet", PSYCHIC, 0, 190, 33, 58, 33, 58, 33, 1.3, 28.5, []),
    203: ("Girafarig", NORMAL, PSYCHIC, 70, 80, 65, 90, 65, 85, 1.5, 41.5, []),
    204: ("Pineco", BUG, 0, 50, 65, 90, 35, 35, 15, 0.6, 7.2, [205]),
    205: ("Forretress", BUG, STEEL, 75, 90, 140, 60, 60, 40, 1.2, 125.8, []),
    206: ("Dunsparce", NORMAL, 0, 100, 70, 70, 65, 65, 45, 1.5, 14.0, []),
    207: ("Gligar", GROUND, FLYING, 65, 75, 105, 35, 65, 85, 1.1, 64.8, []),
    208: ("Steelix", STEEL, GROUND, 75, 85, 200, 55, 65, 30, 9.2, 400.0, []),
    209: ("Snubbull", FAIRY, 0, 60, 80, 50, 40, 40, 30, 0.6, 7.8, [210]),
    210: ("Granbull", FAIRY, 0, 90, 120, 75, 60, 60, 45, 1.4, 48.7, []),
    211: ("Qwilfish", WATER, POISON, 65, 95, 75, 55, 55, 85, 0.5, 3.9, []),
    212: ("Scizor", BUG, STEEL, 70, 130, 100, 55, 80, 65, 1.8, 118.0, []),
    213: ("Shuckle", BUG, ROCK, 20, 10, 230, 10, 230, 5, 0.6, 20.5, []),
    214: ("Heracross", BUG, FIGHTING, 80, 125, 75, 40, 95, 85, 1.5, 54.0, []),
    215: ("Sneasel", DARK, ICE, 55, 95, 55, 35, 75, 115, 0.9, 28.0, []),
    216: ("Teddiursa", NORMAL, 0, 60, 80, 50, 50, 50, 40, 0.6, 8.8, [217]),
    217: ("Ursaring", NORMAL, 0, 90, 130, 75, 75, 75, 55, 1.8, 125.8, []),
    218: ("Slugma", FIRE, 0, 40, 40, 40, 70, 40, 20, 0.7, 35.0, [219]),
    219: ("Magcargo", FIRE, ROCK, 50, 50, 120, 80, 80, 30, 0.8, 55.0, []),
    220: ("Swinub", ICE, GROUND, 50, 50, 40, 30, 30, 50, 0.4, 6.5, [221]),
    221: ("Piloswine", ICE, GROUND, 100, 100, 80, 60, 60, 50, 1.1, 55.8, []),
    222: ("Corsola", WATER, ROCK, 55, 55, 85, 65, 85, 35, 0.6, 5.0, []),
    223: ("Remoraid", WATER, 0, 35, 65, 35, 65, 35, 65, 0.6, 12.0, [224]),
    224: ("Octillery", WATER, 0, 75, 105, 75, 105, 75, 45, 0.9, 28.5, []),
    225: ("Delibird", ICE, FLYING, 45, 55, 45, 65, 45, 75, 0.9, 16.0, []),
    226: ("Mantine", WATER, FLYING, 65, 40, 70, 80, 140, 70, 2.1, 220.0, []),
    227: ("Skarmory", STEEL, FLYING, 65, 80, 140, 40, 70, 70, 1.7, 50.5, []),
    228: ("Houndour", DARK, FIRE, 45, 60, 30, 80, 50, 65, 0.6, 10.8, [229]),
    229: ("Houndoom", DARK, FIRE, 75, 90, 50, 110, 80, 95, 1.4, 35.0, []),
    230: ("Kingdra", WATER, DRAGON, 75, 95, 95, 95, 95, 85, 1.8, 152.0, []),
    231: ("Phanpy", GROUND, 0, 90, 60, 60, 40, 40, 40, 0.5, 33.5, [232]),
    232: ("Donphan", GROUND, 0, 90, 120, 120, 60, 60, 50, 1.1, 120.0, []),
    233: ("Porygon2", NORMAL, 0, 85, 80, 90, 105, 95, 60, 0.6, 32.5, []),
    234: ("Stantler", NORMAL, 0, 73, 95, 62, 85, 65, 85, 1.4, 71.2, []),
    235: ("Smeargle", NORMAL, 0, 55, 20, 35, 20, 45, 75, 1.2, 58.0, []),
    236: ("Tyrogue", FIGHTING, 0, 35, 35, 35, 35, 35, 35, 0.7, 21.0, [106, 107, 237]),
    237: ("Hitmontop", FIGHTING, 0, 50, 95, 95, 35, 110, 70, 1.4, 48.0, []),
    238: ("Smoochum", ICE, PSYCHIC, 45, 30, 15, 85, 65, 65, 0.4, 6.0, [124]),
    239: ("Elekid", ELECTRIC, 0, 45, 63, 37, 65, 55, 95, 0.6, 23.5, [125]),
    240: ("Magby", FIRE, 0, 45, 75, 37, 70, 55, 83, 0.7, 21.4, [126]),
    241: ("Miltank", NORMAL, 0, 95, 80, 105, 40, 70, 100, 1.2, 75.5, []),
    242: ("Blissey", NORMAL, 0, 255, 10, 10, 75, 135, 55, 1.5, 46.8, []),
    243: ("Raikou", ELECTRIC, 0, 90, 85, 75, 115, 100, 115, 1.9, 178.0, []),
    244: ("Entei", FIRE, 0, 115, 115, 85, 90, 75, 100, 2.1, 198.0, []),
    245: ("Suicune", WATER, 0, 100, 75, 115, 90, 115, 85, 2.0, 187.0, []),
    246: ("Larvitar", ROCK, GROUND, 50, 64, 50, 45, 50, 41, 0.6, 72.0, [247]),
    247: ("Pupitar", ROCK, GROUND, 70, 84, 70, 65, 70, 51, 1.2, 152.0, [248]),
    248: ("Tyranitar", ROCK, DARK, 100, 134, 110, 95, 100, 61, 2.0, 202.0, []),
    249: ("Lugia", PSYCHIC, FLYING, 106, 90, 130, 90, 154, 110, 5.2, 216.0, []),
    250: ("Ho-Oh", FIRE, FLYING, 106, 130, 90, 110, 154, 90, 3.8, 199.0, []),
    251: ("Celebi", PSYCHIC, GRASS, 100, 100, 100, 100, 100, 100, 0.6, 5.0, []),
}
LEGENDARY = {243, 244, 245, 249, 250, 251}
BABY = {172, 173, 174, 175, 236, 238, 239, 240}
NO_MODEL = {201}                      # Unown: one prefab per letter, not converted


def stats(pid):
    n, t1, t2, hp, a, d, sa, sd, sp, h, w, ev = SPECIES[pid]
    mod = 1 + (sp - 75) / 500.0
    return (round(2 * (7 / 8 * max(a, sa) + 1 / 8 * min(a, sa)) * mod),
            round(2 * (7 / 8 * max(d, sd) + 1 / 8 * min(d, sd)) * mod),
            hp * 2)


def family(pid):
    """First stage of the family inside Gen 2 (parents are Gen 2 only; Gen 1 links are one-way)."""
    parent = {c: p for p, v in SPECIES.items() for c in v[11] if c in SPECIES}
    while pid in parent:
        pid = parent[pid]
    return pid


def stage(pid):
    parent = {c: p for p, v in SPECIES.items() for c in v[11] if c in SPECIES}
    n = 0
    while pid in parent:
        pid = parent[pid]
        n += 1
    return n


def spawn_weight(pid):
    """Relative wild-spawn weight: first stages common, evolutions rarer, babies/final forms scarce, legendaries never."""
    if pid in LEGENDARY or pid in NO_MODEL:
        return 0.0
    if pid in BABY:
        return 0.25
    st = stage(pid)
    final = not SPECIES[pid][11]
    if st == 0 and not final:
        return 3.0
    if st == 0 and final:
        return 1.0
    return 1.2 if not final else 0.5


# move pools by type (move ids that the 0.35 client knows): quick, charged
QUICK_BY_TYPE = {1: [219, 220, 221, 222, 223], 2: [207, 208, 241], 3: [210, 211], 4: [224, 225, 236], 5: [216, 233], 6: [227],
                 7: [200, 201], 8: [212, 213], 9: [228, 229, 239], 10: [209, 240], 11: [230, 231, 237], 12: [214, 215],
                 13: [205, 206], 14: [226, 234, 235], 15: [217, 218], 16: [204], 17: [202, 203, 238], 18: [203]}
CHARGED_BY_TYPE = {1: [13, 14, 20, 125, 126, 127, 129, 131, 133], 2: [28, 54, 56, 123], 3: [38, 45, 121, 122], 4: [18, 50, 89, 90, 91, 92],
                   5: [26, 31, 46, 94, 95, 96], 6: [32, 62, 63, 64, 65], 7: [22, 49, 99, 100], 8: [69, 70], 9: [36, 72, 74],
                   10: [21, 24, 42, 101, 102, 103, 115], 11: [53, 57, 58, 104, 105, 106, 107], 12: [47, 59, 116, 117, 118],
                   13: [35, 77, 78, 79], 14: [30, 60, 108], 15: [33, 39, 40, 111], 16: [80, 82, 83], 17: [16, 51], 18: [84, 85, 86, 87, 88]}


def movesets(pid):
    """(quick list, charged list): same-type moves first, a Normal fallback, so every Gen 2 species has real moves."""
    n, t1, t2 = SPECIES[pid][:3]
    q, c = [], []
    for t in (t1, t2):
        if t:
            q += QUICK_BY_TYPE.get(t, [])[:2]
            c += CHARGED_BY_TYPE.get(t, [])[:3]
    if not q:
        q = QUICK_BY_TYPE[1][:2]
    if len(c) < 2:
        c += CHARGED_BY_TYPE[1][:2]
    return q[:3], c[:4]


def install(gd):
    """Fill gamedata's STATS / QUICK / CHARGED for 152..251 (keeps the hand-entered ones)."""
    for pid in SPECIES:
        gd.STATS.setdefault(pid, stats(pid))
        q, c = movesets(pid)
        gd.QUICK.setdefault(pid, q)
        gd.CHARGED.setdefault(pid, c)
