#!/bin/bash
# ============================================================
#  Lettore listino CHF Patek — Oracle Zurigo, versione Worker
#  Uso:  sudo bash installa-worker.sh
#  Nessun dominio, nessun certificato: risponde in HTTP sulla
#  porta 8080, protetto da una chiave. Lo chiama solo il Worker.
# ============================================================
set -e

CHIAVE="${PP_CHIAVE:-$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-22)}"

echo ">>> Aggiornamento pacchetti"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3

echo ">>> Installazione del lettore"
mkdir -p /opt/ppreader
cat > /opt/ppreader/reader.py <<'PYEOF'
#!/usr/bin/env python3
"""Lettore prezzi Patek — gira su IP svizzero, risponde in JSON."""
import json, os, re, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

CHIAVE = os.environ.get("PP_CHIAVE", "")
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15")
CONSENTITO = re.compile(r"^https://(www\.)?patek\.com/", re.I)
CACHE = {}
TTL = 6 * 3600

def scarica(url):
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Accept": "text/html,application/xhtml+xml",
        "Accept-Language": "de-CH,de;q=0.9,en;q=0.8",
    })
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", "ignore")

def pulisci(s):
    s = re.sub(r"[\u2019'\u00a0\s]", "", s)
    s = re.sub(r"[.,](\d{2})$", "", s)
    return int(re.sub(r"[^0-9]", "", s) or 0)

def leggi_prezzo(raw):
    t = re.sub(r"<script[\s\S]*?</script>", " ", raw, flags=re.I)
    t = re.sub(r"<style[\s\S]*?</style>", " ", t, flags=re.I)
    t = re.sub(r"<[^>]+>", " ", t)
    t = t.replace("&nbsp;", " ").replace("&#8217;", "\u2019").replace("&rsquo;", "\u2019")
    t = t.replace("&euro;", "\u20ac")
    t = re.sub(r"\s+", " ", t)
    prove = [
        (r"(?:CHF|SFr\.?)\s?([\d][\d\u2019'.,\s]{3,})", "CHF"),
        (r"([\d][\d\u2019'.,\s]{3,})\s?(?:CHF|SFr\.?)", "CHF"),
        (r"\u20ac\s?([\d][\d.,\s]{3,})", "EUR"),
        (r"\$\s?([\d][\d,]{3,})", "USD"),
    ]
    for pat, cur in prove:
        m = re.search(pat, t, re.I)
        if m:
            v = pulisci(m.group(1))
            if 1000 < v < 100000000:
                return {"valuta": cur, "prezzo": v}
    return None

class Handler(BaseHTTPRequestHandler):
    def _invia(self, codice, dati):
        corpo = json.dumps(dati, ensure_ascii=False).encode()
        self.send_response(codice)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(corpo)))
        self.end_headers()
        self.wfile.write(corpo)

    def do_GET(self):
        q = parse_qs(urlparse(self.path).query)
        if CHIAVE and (q.get("k") or [""])[0] != CHIAVE:
            return self._invia(403, {"ok": False, "errore": "chiave mancante"})
        url = (q.get("u") or [""])[0]
        if not CONSENTITO.match(url):
            return self._invia(400, {"ok": False, "errore": "consentito solo patek.com"})
        v = CACHE.get(url)
        if v and time.time() - v[0] < TTL:
            return self._invia(200, v[1])
        try:
            p = leggi_prezzo(scarica(url))
            out = {"ok": bool(p), "url": url}
            if p:
                out.update(p)
            else:
                out["errore"] = "nessun prezzo trovato"
            CACHE[url] = (time.time(), out)
            return self._invia(200, out)
        except Exception as e:
            return self._invia(200, {"ok": False, "url": url, "errore": str(e)})

    def log_message(self, *a):
        pass

if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PYEOF

cat > /etc/systemd/system/ppreader.service <<SVCEOF
[Unit]
Description=Lettore prezzi Patek
After=network.target

[Service]
Environment=PP_CHIAVE=${CHIAVE}
ExecStart=/usr/bin/python3 /opt/ppreader/reader.py
Restart=always
User=nobody

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now ppreader

echo ">>> Apertura porta 8080 nel firewall della macchina"
iptables -I INPUT 1 -p tcp --dport 8080 -j ACCEPT
netfilter-persistent save 2>/dev/null || (apt-get install -y -qq iptables-persistent && netfilter-persistent save)

IP=$(curl -s https://ipinfo.io/ip || echo "INDIRIZZO_IP")

sleep 2
echo ""
echo "=================================================================="
echo "  FATTO"
echo ""
echo "  Prova locale:"
curl -s "http://127.0.0.1:8080/?k=${CHIAVE}&u=https://www.patek.com/en/collection/nautilus/5811-1g-001" || true
echo ""
echo ""
echo "  Copia queste due righe e mandale a Claude:"
echo "     IP     = ${IP}"
echo "     CHIAVE = ${CHIAVE}"
echo "=================================================================="
