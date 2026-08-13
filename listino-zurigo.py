#!/usr/bin/env python3
"""Raccolta listino CHF Patek Philippe — da eseguire nel Cloud Shell Oracle (regione Zurigo)."""

import json, re, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor

BASE = "https://www.patek.com"
FINDER = BASE + "/en/collection/watch-finder"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15")

COLLECTIONS = {
    "grand-complications", "complications", "calatrava", "gondolo",
    "golden-ellipse", "cubitus", "nautilus", "aquanaut",
    "twenty4", "pocket-watches", "rare-handcrafts",
}

def get(url):
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Accept": "text/html,application/xhtml+xml",
        "Accept-Language": "de-CH,de;q=0.9,en;q=0.8",
    })
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", "ignore")

def slug_to_ref(slug):
    s = slug.upper().split("-")
    return s[0] + "/" + s[1] + "-" + "-".join(s[2:]) if len(s) >= 3 else "-".join(s)

def clean_num(s):
    s = re.sub(r"[\u2019'\u00a0\s]", "", s)
    s = re.sub(r"[.,](\d{2})$", "", s)
    return int(re.sub(r"[^0-9]", "", s) or 0)

def parse_chf(raw):
    t = re.sub(r"<script[\s\S]*?</script>", " ", raw, flags=re.I)
    t = re.sub(r"<style[\s\S]*?</style>", " ", t, flags=re.I)
    t = re.sub(r"<[^>]+>", " ", t)
    t = t.replace("&nbsp;", " ").replace("&#8217;", "\u2019").replace("&rsquo;", "\u2019")
    t = re.sub(r"\s+", " ", t)
    for pat in (r"(?:CHF|SFr\.?)\s?([\d][\d\u2019'.,\s]{3,})",
                r"([\d][\d\u2019'.,\s]{3,})\s?(?:CHF|SFr\.?)"):
        m = re.search(pat, t, re.I)
        if m:
            v = clean_num(m.group(1))
            if 1000 < v < 100000000:
                return v
    return None

def main():
    print("Lettura elenco modelli...", flush=True)
    html = get(FINDER)

    items, seen = [], set()
    for m in re.finditer(r'href=["\']([^"\']*?/collection/([a-z0-9-]+)/([a-z0-9-]+))/?["\']',
                         html, re.I):
        col, slug = m.group(2).lower(), m.group(3).lower()
        if col not in COLLECTIONS or slug in ("all-watches", "all-models"):
            continue
        key = col + "/" + slug
        if key in seen:
            continue
        seen.add(key)
        items.append((slug_to_ref(slug), BASE + "/en/collection/" + key))

    print(f"Modelli trovati: {len(items)}", flush=True)
    if not items:
        print("Nessun modello: patek.com non ha restituito l'elenco.")
        sys.exit(1)

    prezzi, mancanti, fatti = {}, 0, 0

    def leggi(it):
        ref, url = it
        try:
            return ref, parse_chf(get(url))
        except Exception:
            return ref, None

    with ThreadPoolExecutor(max_workers=6) as pool:
        for ref, v in pool.map(leggi, items):
            fatti += 1
            if v:
                prezzi[ref] = v
            else:
                mancanti += 1
            if fatti % 25 == 0:
                print(f"  {fatti}/{len(items)} — prezzi {len(prezzi)}", flush=True)

    with open("listino-chf.json", "w") as f:
        json.dump(prezzi, f, ensure_ascii=False)

    print(f"\nFATTO — {len(prezzi)} prezzi in CHF, {mancanti} senza prezzo")
    print("Salvato in listino-chf.json\n")
    print(json.dumps(prezzi, ensure_ascii=False))

if __name__ == "__main__":
    main()
