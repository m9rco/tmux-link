#!/usr/bin/env python3
"""Convert rime-pinyin-simp's weighted dictionary into an offline keyboard asset."""
import json
from collections import defaultdict
from pathlib import Path
import sys

source, destination = map(Path, sys.argv[1:])
groups = defaultdict(list)
for line in source.read_text().split("\n...\n", 1)[1].splitlines():
    if not line or line.startswith("#"):
        continue
    word, spelling, weight = line.split("\t")
    groups[spelling.replace(" ", "")].append((int(weight), word, spelling))

# Keep syllable boundaries for homographs such as xian and xi'an. Most
# spellings have only one segmentation, so the common lookup stays compact.
def words(entries):
    return " ".join(dict.fromkeys(word for _, word, _ in sorted(entries, reverse=True)))

lexicon = {}
for spelling, entries in sorted(groups.items()):
    lexicon[spelling] = words(entries)
    segments = {entry[2] for entry in entries}
    if len(segments) > 1:
        for segment in sorted(segments):
            if " " in segment:
                lexicon[segment.replace(" ", "'")] = words(e for e in entries if e[2] == segment)

with destination.open("w") as output:
    output.write("// Generated from rime-pinyin-simp. See SOURCES.md and LICENSE-pinyin-simp.\n")
    output.write("const pinyinLexicon = {\n")
    output.write(",\n".join(json.dumps(key) + ":" + json.dumps(value, ensure_ascii=False)
                            for key, value in lexicon.items()))
    output.write("\n};\n")
