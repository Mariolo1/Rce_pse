 
#!/bin/bash
set -Eeuo pipefail

echo "======================================"
echo " INSTALACJA RCE-PSE"
echo "======================================"

# Katalog projektu
mkdir -p data
mkdir -p logs

# requirements.txt
cat > requirements.txt <<'EOF'
requests>=2.32,<3
EOF

# app.py
cat > app.py <<'PYTHON'
import json
import logging
import time
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import requests

API_URL = "https://api.raporty.pse.pl/api/rce-pln"
DATA_FILE = Path("/data/rce.json")
INTERVAL = 900
WARSAW = ZoneInfo("Europe/Warsaw")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s"
)

session = requests.Session()
session.headers.update({
    "User-Agent": "RCE-PSE-Collector/1.0"
})


def pobierz_date(data):
    params = {
        "$filter": f"business_date eq '{data}'",
        "$select": "dtime,period,rce_pln,business_date",
        "$orderby": "dtime asc",
        "$top": "200"
    }

    response = session.get(
        API_URL,
        params=params,
        timeout=30
    )
    response.raise_for_status()

    return response.json().get("value", [])


def pobierz_i_zapisz():
    dzisiaj = datetime.now(WARSAW).date()
    wszystkie = []

    for offset in (0, 1):
        data = (
            dzisiaj + timedelta(days=offset)
        ).isoformat()

        try:
            rekordy = pobierz_date(data)

            for rekord in rekordy:
                cena = rekord.get("rce_pln")

                if cena is None:
                    continue

                cena = float(cena)

                wszystkie.append({
                    "data": rekord.get("business_date"),
                    "czas": rekord.get("dtime"),
                    "okres": rekord.get("period"),
                    "cena_pln_mwh": cena,
                    "cena_pln_kwh": round(cena / 1000, 6)
                })

            logging.info(
                "%s: pobrano %d rekordow",
                data, len(rekordy)
            )

        except requests.RequestException:
            logging.exception(
                "Blad pobierania danych dla %s", data
            )

    if not wszystkie:
        logging.warning(
            "Brak nowych danych. Zachowano poprzedni plik."
        )
        return

    wszystkie.sort(
        key=lambda x: (x["data"] or "", x["czas"] or "")
    )

    wynik = {
        "aktualizacja": datetime.now(WARSAW).isoformat(),
        "zrodlo": "PSE",
        "liczba_rekordow": len(wszystkie),
        "ceny": wszystkie
    }

    DATA_FILE.parent.mkdir(parents=True, exist_ok=True)

    temp = DATA_FILE.with_suffix(".tmp")
    temp.write_text(
        json.dumps(wynik, ensure_ascii=False, indent=2),
        encoding="utf-8"
    )
    temp.replace(DATA_FILE)

    logging.info(
        "Zapisano %d rekordow do %s",
        len(wszystkie), DATA_FILE
    )


if __name__ == "__main__":
    logging.info("Uruchomiono kolektor PSE RCE")

    while True:
        try:
            pobierz_i_zapisz()
        except Exception:
            logging.exception("Blad kolektora")

        time.sleep(INTERVAL)
PYTHON

# Dockerfile
cat > Dockerfile <<'EOF'
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV TZ=Europe/Warsaw

WORKDIR /app

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

CMD ["python", "-u", "app.py"]
EOF

# docker-compose.yml
cat > docker-compose.yml <<'EOF'
services:
  rce-pse:
    build: .
    container_name: rce-pse
    restart: unless-stopped
    environment:
      TZ: Europe/Warsaw
    volumes:
      - ./data:/data
EOF

echo "Pliki projektu utworzone."

# Budowanie i uruchomienie
docker compose up -d --build

echo
echo "======================================"
echo " PROJEKT RCE-PSE URUCHOMIONY"
echo "======================================"

docker compose ps

echo
echo "Ostatnie logi:"
docker compose logs --tail=20

echo
echo "Dane beda zapisywane w:"
echo "$(pwd)/data/rce.json"

echo
echo "Aby obserwowac logi:"
echo "docker logs -f rce-pse"

