#!/usr/bin/env python3
"""Build the extended CJK glyph set for main.odin from real Chinese text.

Fetches several Chinese Wikipedia article plaintexts, counts Han character
frequency, and emits an Odin string literal with the most common chars.
"""
import json
import urllib.parse
import urllib.request
from collections import Counter

TITLES = ["汉字", "中国菜", "中国历史", "食物", "水果", "蔬菜", "肉", "辣",
          "甜", "酸", "中国文化", "汉语", "中国地理", "电子游戏", "蛇",
          "苹果", "蘑菇", "糖果", "冰", "火", "中国文化史"]

def fetch(title):
    q = urllib.parse.urlencode({
        "action": "query", "prop": "extracts", "explaintext": "1",
        "format": "json", "titles": title, "redirects": "1",
    })
    url = "https://zh.wikipedia.org/w/api.php?" + q
    req = urllib.request.Request(url, headers={"User-Agent": "glyphset/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.load(r)
    for page in data["query"]["pages"].values():
        return page.get("extract", "")
    return ""

counter = Counter()
for t in TITLES:
    try:
        text = fetch(t)
    except Exception as e:
        print("skip", t, e)
        continue
    for ch in text:
        if "一" <= ch <= "鿿":  # CJK Unified Ideographs
            counter[ch] += 1
    print(f"{t}: {len(text)} chars")

TOP_N = 1400
common = [ch for ch, _ in counter.most_common(TOP_N)]
# Sort by codepoint for a stable, diff-friendly literal
common.sort()
s = "".join(common)
print("unique:", len(counter), "-> selected:", len(s))
with open("common_cjk.txt", "w", encoding="utf-8") as f:
    f.write(s)
