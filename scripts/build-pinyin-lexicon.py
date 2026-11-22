#!/usr/bin/env python3
"""Convert rime-pinyin-simp's weighted dictionary into an offline keyboard asset."""
import json
import math
from collections import defaultdict
from pathlib import Path
import sys

source, destination = map(Path, sys.argv[1:])
groups = defaultdict(dict)
for line in source.read_text().split("\n...\n", 1)[1].splitlines():
    if not line or line.startswith("#"):
        continue
    word, spelling, weight = line.split("\t")
    syllables = spelling.split()
    length = boundaries = 0
    for syllable in syllables[:-1]:
        length += len(syllable)
        boundaries |= 1 << length
    entries = groups["".join(syllables)]
    key = (word, boundaries)
    entries[key] = max(entries.get(key, 0), int(weight))

# Store additive unigram costs in hundredths of a natural logarithm. The mask
# marks legal apostrophe positions for this particular pronunciation.
total = sum(weight + 1 for entries in groups.values() for weight in entries.values())
with destination.open("w") as output:
    output.write("// Generated from rime-pinyin-simp. See SOURCES.md and LICENSE-pinyin-simp.\n")
    output.write(f"const maxPinyinWordLength = {max(map(len, groups))};\n")
    output.write("const pinyinLexicon = {\n")
    rows = []
    for spelling, entries in sorted(groups.items()):
        tokens = []
        for (word, mask), weight in sorted(entries.items(), key=lambda entry: (-entry[1], entry[0])):
            cost = round(100 * math.log(total / (weight + 1)))
            tokens.append(f"{word}:{cost}" + (f":{mask}" if mask else ""))
        rows.append(json.dumps(spelling) + ":" + json.dumps(" ".join(tokens), ensure_ascii=False))
    output.write(",\n".join(rows) + "\n};\n")
