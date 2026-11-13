
#!/bin/bash
set -Eeuo pipefail

echo "======================================"
echo " AKTUALIZACJA RCE-PSE"
echo "======================================"

mkdir -p data/current data/archive data/monthly_pending data/reports data/sent logs

# Nie nadpisuj istniejących danych logowania
if [ ! -f .env ]; then
cat > .env <<'ENV'
SMTP_HOST=poczta.interia.pl
SMTP_PORT=465
SMTP_USER=mariusz.grabovski@interia.pl
SMTP_PASSWORD=WPISZ_TUTAJ_HASLO
SMTP_TO=mariusz.grabovski@interia.pl
ENV
chmod 600 .env
fi

# Wymagane biblioteki
cat > requirements.txt <<'EOF'
requests>=2.32,<3
openpyxl>=3.1,<4
EOF

# Główny program
cat > app.py <<'PYTHON'
import os
import json
import time
import ssl
import smtplib
import logging
import calendar
from pathlib import Path
from datetime import datetime, date, timedelta
from zoneinfo import ZoneInfo
from email.message import EmailMessage

import requests
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment
from openpyxl.utils import get_column_letter

# ------------------------------------------------
# KONFIGURACJA
# ------------------------------------------------

API_URL = "https://api.raporty.pse.pl/api/rce-pln"
TZ = ZoneInfo("Europe/Warsaw")
INTERVAL = 900

BASE = Path("/data")
CURRENT = BASE / "current"
ARCHIVE = BASE / "archive"
PENDING = BASE / "monthly_pending"
REPORTS = BASE / "reports"
SENT = BASE / "sent"

SMTP_HOST = os.getenv("SMTP_HOST", "poczta.interia.pl")
SMTP_PORT = int(os.getenv("SMTP_PORT", "465"))
SMTP_USER = os.getenv("SMTP_USER", "")
SMTP_PASSWORD = os.getenv("SMTP_PASSWORD", "")
SMTP_TO = os.getenv("SMTP_TO", "")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s"
)

session = requests.Session()
session.headers.update({
    "User-Agent": "RCE-PSE-Collector/2.0"
})

for folder in (CURRENT, ARCHIVE, PENDING, REPORTS, SENT):
    folder.mkdir(parents=True, exist_ok=True)


# ------------------------------------------------
# POMOCNICZE
# ------------------------------------------------

def zapisz_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(
        json.dumps(data, ensure_ascii=False, indent=2),
        encoding="utf-8"
    )
    tmp.replace(path)


def odczytaj_json(path):
    if not path.exists():
        return []
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        logging.exception("Nie można odczytać %s", path)
        return []


def polacz_rekordy(stare, nowe):
    wynik = {}

    for r in stare + nowe:
        klucz = (
            r.get("data"),
            r.get("czas"),
            r.get("okres")
        )
        wynik[klucz] = r

    return sorted(
        wynik.values(),
        key=lambda r: (
            r.get("data") or "",
            r.get("czas") or ""
        )
    )


# ------------------------------------------------
# POBIERANIE CEN PSE
# ------------------------------------------------

def pobierz_date(data):
    # Znak $ musi pozostać niezakodowany.
    query = (
        f"$filter=business_date%20eq%20%27{data}%27"
        "&$select=dtime%2Cperiod%2Crce_pln%2Cbusiness_date"
        "&$orderby=dtime%20asc"
        "&$first=200"
    )

    response = session.get(
        f"{API_URL}?{query}",
        timeout=30
    )

    if not response.ok:
        logging.error("PSE: %s", response.text[:1500])

    response.raise_for_status()

    rekordy = response.json().get("value", [])
    wynik = []

    for r in rekordy:
        cena = r.get("rce_pln")

        if cena is None:
            continue

        cena = float(cena)

        wynik.append({
            "data": r.get("business_date"),
            "czas": r.get("dtime"),
            "okres": r.get("period"),
            "cena_pln_mwh": cena,
            "cena_pln_kwh": round(cena / 1000, 6)
        })

    return wynik


# ------------------------------------------------
# ARCHIWUM I DANE OPERACYJNE
# ------------------------------------------------

def zapisz_dzien(data, rekordy):
    if not rekordy:
        return

    path = ARCHIVE / f"{data}.json"
    stare = odczytaj_json(path)
    polaczone = polacz_rekordy(stare, rekordy)

    zapisz_json(path, polaczone)

    logging.info(
        "Archiwum %s: %d rekordow",
        data, len(polaczone)
    )


def zapisz_miesiac(data, rekordy):
    if not rekordy:
        return

    miesiac = data[:7]
    path = PENDING / f"{miesiac}.json"

    stare = odczytaj_json(path)
    polaczone = polacz_rekordy(stare, rekordy)

    zapisz_json(path, polaczone)


def zapisz_biezace(wszystkie):
    if not wszystkie:
        return

    wynik = {
        "aktualizacja": datetime.now(TZ).isoformat(),
        "zrodlo": "PSE",
        "liczba_rekordow": len(wszystkie),
        "ceny": wszystkie
    }

    zapisz_json(CURRENT / "rce.json", wynik)


# ------------------------------------------------
# KOMPLETNOSC MIESIACA
# ------------------------------------------------

def oczekiwane_interwaly(d):
    poczatek = datetime.combine(
        d, datetime.min.time(), tzinfo=TZ
    )
    koniec = datetime.combine(
        d + timedelta(days=1),
        datetime.min.time(),
        tzinfo=TZ
    )

    return int((koniec.timestamp() - poczatek.timestamp()) / 900)


def miesiac_poprzedni():
    dzis = datetime.now(TZ).date()

    if dzis.month == 1:
        return f"{dzis.year - 1}-12"

    return f"{dzis.year}-{dzis.month - 1:02d}"


def sprawdz_kompletnosc(miesiac, rekordy):
    rok, mc = map(int, miesiac.split("-"))
    liczba_dni = calendar.monthrange(rok, mc)[1]

    for dzien in range(1, liczba_dni + 1):
        data = date(rok, mc, dzien)
        data_str = data.isoformat()

        dzienne = [
            r for r in rekordy
            if r.get("data") == data_str
        ]

        unikalne = {
            (r.get("czas"), r.get("okres"))
            for r in dzienne
        }

        oczekiwane = oczekiwane_interwaly(data)

        if len(unikalne) != oczekiwane:
            logging.warning(
                "Miesiac %s niekompletny: %s ma %d/%d rekordow",
                miesiac, data_str, len(unikalne), oczekiwane
            )
            return False

    return True


# ------------------------------------------------
# EXCEL
# ------------------------------------------------

def generuj_excel(miesiac, rekordy):
    path = REPORTS / f"RCE_{miesiac}.xlsx"

    wb = Workbook()
    ws = wb.active
    ws.title = "Ceny RCE"

    naglowki = [
        "Data",
        "Godzina",
        "Cena PLN/MWh",
        "Cena PLN/kWh"
    ]

    ws.append(naglowki)

    for cell in ws[1]:
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = PatternFill(
            "solid", fgColor="1F4E78"
        )
        cell.alignment = Alignment(horizontal="center")

    uporzadkowane = sorted(
        rekordy,
        key=lambda r: (r["data"], r["czas"] or "")
    )

    for r in uporzadkowane:
        ws.append([
            r["data"],
            r["okres"] or r["czas"],
            r["cena_pln_mwh"],
            r["cena_pln_kwh"]
        ])

    ceny = [r["cena_pln_mwh"] for r in uporzadkowane]

    ws.freeze_panes = "A2"
    ws.auto_filter.ref = ws.dimensions

    szerokosci = [15, 23, 20, 20]

    for i, szerokosc in enumerate(szerokosci, 1):
        ws.column_dimensions[
            get_column_letter(i)
        ].width = szerokosc

    podsumowanie = wb.create_sheet("Podsumowanie")

    podsumowanie.append(["Parametr", "Wartość"])
    podsumowanie.append(["Miesiąc", miesiac])
    podsumowanie.append(["Liczba interwałów", len(ceny)])
    podsumowanie.append([
        "Średnia cena PLN/MWh",
        round(sum(ceny) / len(ceny), 3)
    ])
    podsumowanie.append(["Minimum PLN/MWh", min(ceny)])
    podsumowanie.append(["Maksimum PLN/MWh", max(ceny)])

    for cell in podsumowanie[1]:
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = PatternFill(
            "solid", fgColor="1F4E78"
        )

    podsumowanie.column_dimensions["A"].width = 30
    podsumowanie.column_dimensions["B"].width = 25

    wb.save(path)

    logging.info("Wygenerowano Excel: %s", path)

    return path


# ------------------------------------------------
# WYSYŁKA E-MAIL INTERIA
# ------------------------------------------------

def wyslij_email(miesiac, plik):
    if not all((SMTP_USER, SMTP_PASSWORD, SMTP_TO)):
        raise RuntimeError(
            "Brak konfiguracji SMTP w pliku .env"
        )

    msg = EmailMessage()
    msg["Subject"] = f"Raport miesięczny cen energii RCE – {miesiac}"
    msg["From"] = SMTP_USER
    msg["To"] = SMTP_TO

    msg.set_content(
        f"""Raport miesięczny cen energii elektrycznej RCE.

Miesiąc: {miesiac}

Źródło danych: PSE
Interwał: 15 minut

W załączeniu znajduje się raport Excel.
Wiadomość wygenerowana automatycznie przez RCE-PSE.
"""
    )

    with open(plik, "rb") as f:
        msg.add_attachment(
            f.read(),
            maintype="application",
            subtype="vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            filename=plik.name
        )

    context = ssl.create_default_context()

    with smtplib.SMTP_SSL(
        SMTP_HOST,
        SMTP_PORT,
        context=context,
        timeout=40
    ) as smtp:
        smtp.login(SMTP_USER, SMTP_PASSWORD)
        smtp.send_message(msg)

    logging.info(
        "Raport %s wysłany na %s",
        miesiac, SMTP_TO
    )


# ------------------------------------------------
# ZAMKNIECIE MIESIACA
# ------------------------------------------------

def zamknij_miesiac(miesiac):
    pending_file = PENDING / f"{miesiac}.json"
    sent_file = SENT / f"{miesiac}.json"

    if sent_file.exists():
        return

    rekordy = odczytaj_json(pending_file)

    if not rekordy:
        return

    if not sprawdz_kompletnosc(miesiac, rekordy):
        logging.warning(
            "Raport %s nie zostanie wysłany – brak kompletnych danych.",
            miesiac
        )
        return

    plik = generuj_excel(miesiac, rekordy)

    try:
        wyslij_email(miesiac, plik)

        # Znacznik zapobiega ponownej wysyłce
        zapisz_json(sent_file, {
            "miesiac": miesiac,
            "wyslano": datetime.now(TZ).isoformat(),
            "odbiorca": SMTP_TO
        })

        # Usuwamy dane miesięczne dopiero po wysyłce
        pending_file.unlink(missing_ok=True)
        plik.unlink(missing_ok=True)

        logging.info(
            "Miesiac %s zamkniety. Dane miesieczne usuniete.",
            miesiac
        )

    except Exception:
        logging.exception(
            "Wysyłka raportu %s nie powiodła się. Dane zachowane.",
            miesiac
        )


# ------------------------------------------------
# CZYSZCZENIE ARCHIWUM 30 DNI
# ------------------------------------------------

def czysc_archiwum():
    granica = datetime.now(TZ).date() - timedelta(days=30)

    for path in ARCHIVE.glob("*.json"):
        try:
            data = date.fromisoformat(path.stem)

            if data < granica:
                path.unlink()
                logging.info("Usunięto stare archiwum: %s", path.name)

        except ValueError:
            logging.warning("Nieprawidłowa nazwa archiwum: %s", path)


# ------------------------------------------------
# GLOWNA PETLA
# ------------------------------------------------

def wykonaj():
    dzisiaj = datetime.now(TZ).date()
    wszystkie = []

    for offset in (0, 1):
        data = (dzisiaj + timedelta(days=offset)).isoformat()

        try:
            rekordy = pobierz_date(data)
            wszystkie.extend(rekordy)

            logging.info(
                "%s: pobrano %d rekordow",
                data, len(rekordy)
            )

            # Archiwizujemy tylko dzień bieżący.
            # Dane jutrzejsze pozostają w pliku operacyjnym.
            if offset == 0 and rekordy:
                zapisz_dzien(data, rekordy)
                zapisz_miesiac(data, rekordy)

        except requests.RequestException:
            logging.exception("Blad pobierania %s", data)

    zapisz_biezace(wszystkie)

    # Pierwszego dnia nowego miesiąca próbujemy zamknąć poprzedni.
    # Ponawiamy próbę co 15 minut, jeśli brakuje danych lub poczta
    # jest chwilowo niedostępna.
    poprzedni = miesiac_poprzedni()
    zamknij_miesiac(poprzedni)

    czysc_archiwum()


if __name__ == "__main__":
    logging.info("Start RCE-PSE 2.0")

    while True:
        try:
            wykonaj()
        except Exception:
            logging.exception("Nieoczekiwany blad kolektora")

        time.sleep(INTERVAL)
PYTHON

# Dockerfile
cat > Dockerfile <<'DOCKER'
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV TZ=Europe/Warsaw

WORKDIR /app

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

CMD ["python", "-u", "app.py"]
DOCKER

# Docker Compose
cat > docker-compose.yml <<'YAML'
services:
  rce-pse:
    build: .
    container_name: rce-pse
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: Europe/Warsaw
    volumes:
      - ./data:/data
      - ./logs:/logs
YAML

echo
echo "Pliki projektu zostały utworzone."
echo

if grep -q 'WPISZ_TUTAJ_HASLO' .env; then
    echo "UWAGA: Najpierw uzupelnij haslo Interia w pliku .env"
    echo "nano .env"
    echo
    echo "Nastepnie uruchom:"
    echo "docker compose up -d --build"
    exit 0
fi

docker compose up -d --build

echo
echo "======================================"
echo " RCE-PSE 2.0 GOTOWY"
echo "======================================"

docker compose ps
docker compose logs --tail=20
