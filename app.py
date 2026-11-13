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
INTERVAL = 900  # 15 minut
MAX_BACKFILL_DAYS = 30  # dzisiaj + 29 poprzednich dni

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
    format="%(asctime)s %(levelname)s %(message)s",
)

session = requests.Session()
session.headers.update({"User-Agent": "RCE-PSE-Collector/2.1"})

for folder in (CURRENT, ARCHIVE, PENDING, REPORTS, SENT):
    folder.mkdir(parents=True, exist_ok=True)


# ------------------------------------------------
# POMOCNICZE
# ------------------------------------------------

def zapisz_json(path, data):
    """Zapis atomowy: najpierw plik tymczasowy, potem podmiana."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(
        json.dumps(data, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    tmp.replace(path)


def odczytaj_json(path):
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, list) else []
    except (json.JSONDecodeError, OSError):
        logging.exception("Nie można odczytać %s", path)
        return []


def polacz_rekordy(stare, nowe):
    wynik = {}
    for r in (stare or []) + (nowe or []):
        if not isinstance(r, dict):
            continue
        klucz = (r.get("data"), r.get("czas"), r.get("okres"))
        # Nowy rekord zastępuje poprzedni rekord o tym samym kluczu.
        wynik[klucz] = r
    return sorted(
        wynik.values(),
        key=lambda r: (r.get("data") or "", r.get("czas") or "", str(r.get("okres") or "")),
    )


def poprzedni_miesiac(dzis=None):
    dzis = dzis or datetime.now(TZ).date()
    pierwszy_biezacego = dzis.replace(day=1)
    return (pierwszy_biezacego - timedelta(days=1)).strftime("%Y-%m")


# ------------------------------------------------
# POBIERANIE CEN PSE
# ------------------------------------------------

def pobierz_date(data):
    # Zachowujemy literalne znaki $ w nazwach parametrów API.
    query = (
        f"$filter=business_date%20eq%20%27{data}%27"
        "&$select=dtime%2Cperiod%2Crce_pln%2Cbusiness_date"
        "&$orderby=dtime%20asc"
        "&$first=200"
    )
    response = session.get(f"{API_URL}?{query}", timeout=30)
    if not response.ok:
        logging.error("PSE HTTP %s: %s", response.status_code, response.text[:1000])
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
            "cena_pln_kwh": round(cena / 1000, 6),
        })
    return wynik


# ------------------------------------------------
# KOMPLETNOŚĆ DNIA I MIESIĄCA
# ------------------------------------------------

def oczekiwane_interwaly(d):
    poczatek = datetime.combine(d, datetime.min.time(), tzinfo=TZ)
    koniec = datetime.combine(d + timedelta(days=1), datetime.min.time(), tzinfo=TZ)
    return int((koniec.timestamp() - poczatek.timestamp()) / 900)


def dzien_kompletny(data, rekordy):
    dzienne = [r for r in rekordy if r.get("data") == data.isoformat()]
    unikalne = {
        (r.get("czas"), r.get("okres"))
        for r in dzienne
        if r.get("cena_pln_mwh") is not None
    }
    return len(unikalne) == oczekiwane_interwaly(data)


def sprawdz_kompletnosc(miesiac, rekordy):
    rok, mc = map(int, miesiac.split("-"))
    liczba_dni = calendar.monthrange(rok, mc)[1]
    for dzien in range(1, liczba_dni + 1):
        data = date(rok, mc, dzien)
        if not dzien_kompletny(data, rekordy):
            dzienne = [r for r in rekordy if r.get("data") == data.isoformat()]
            liczba = len({(r.get("czas"), r.get("okres")) for r in dzienne})
            logging.warning(
                "Miesiąc %s niekompletny: %s ma %d/%d interwałów",
                miesiac, data.isoformat(), liczba, oczekiwane_interwaly(data),
            )
            return False
    return True


# ------------------------------------------------
# ARCHIWUM I DANE OPERACYJNE
# ------------------------------------------------

def zapisz_dzien(data, rekordy):
    if not rekordy:
        return []
    path = ARCHIVE / f"{data}.json"
    polaczone = polacz_rekordy(odczytaj_json(path), rekordy)
    zapisz_json(path, polaczone)
    logging.info("Archiwum %s: %d rekordów", data, len(polaczone))
    return polaczone


def zapisz_miesiac(data, rekordy):
    if not rekordy:
        return
    miesiac = data[:7]
    path = PENDING / f"{miesiac}.json"
    polaczone = polacz_rekordy(odczytaj_json(path), rekordy)
    zapisz_json(path, polaczone)


def zapisz_biezace(wszystkie):
    if not wszystkie:
        logging.warning("Nie zapisano current/rce.json – brak pobranych rekordów.")
        return
    wynik = {
        "aktualizacja": datetime.now(TZ).isoformat(),
        "zrodlo": "PSE",
        "liczba_rekordow": len(wszystkie),
        "ceny": polacz_rekordy([], wszystkie),
    }
    zapisz_json(CURRENT / "rce.json", wynik)


def daty_do_uzupelnienia(dzis):
    """Ostatnie 30 dni oraz cały poprzedni miesiąc, dopóki raport
    za ten miesiąc nie został oznaczony jako wysłany.

    Dzięki temu uruchomienie aplikacji np. 13 listopada nadal uzupełni
    1–14 października, jeśli październikowy raport nie został wysłany.
    """
    daty = {dzis - timedelta(days=i) for i in range(MAX_BACKFILL_DAYS)}
    miesiac = poprzedni_miesiac(dzis)
    sent_file = SENT / f"{miesiac}.json"

    if not sent_file.exists():
        rok, mc = map(int, miesiac.split("-"))
        liczba_dni = calendar.monthrange(rok, mc)[1]
        daty.update(date(rok, mc, d) for d in range(1, liczba_dni + 1))

    return sorted(daty)


def uzupelnij_archiwum(dzis):
    """Odtwarza brakujące dni z ostatnich 30 dni z API PSE.
    Kompletne dni z lokalnego archiwum nie są niepotrzebnie pobierane ponownie.
    Dane z archiwum są zawsze synchronizowane z monthly_pending.
    """
    biezace_i_jutrzejsze = []
    for data in daty_do_uzupelnienia(dzis):
        data_str = data.isoformat()
        path = ARCHIVE / f"{data_str}.json"
        lokalne = odczytaj_json(path)

        if lokalne:
            zapisz_miesiac(data_str, lokalne)

        # Dzień dzisiejszy odświeżamy w każdym cyklu; przeszłość pobieramy,
        # jeśli pliku brakuje lub lokalny dzień jest niekompletny.
        if data < dzis and dzien_kompletny(data, lokalne):
            continue

        try:
            pobrane = pobierz_date(data_str)
            logging.info("%s: pobrano %d rekordów", data_str, len(pobrane))
            if pobrane:
                polaczone = zapisz_dzien(data_str, pobrane)
                zapisz_miesiac(data_str, polaczone)
                if data == dzis:
                    biezace_i_jutrzejsze.extend(pobrane)
        except requests.RequestException:
            logging.exception("Błąd pobierania %s", data_str)

    # Jutro pozostaje wyłącznie w pliku operacyjnym, nie trafia do archiwum.
    jutro = dzis + timedelta(days=1)
    try:
        rekordy_jutro = pobierz_date(jutro.isoformat())
        logging.info("%s: pobrano %d rekordów", jutro.isoformat(), len(rekordy_jutro))
        biezace_i_jutrzejsze.extend(rekordy_jutro)
    except requests.RequestException:
        logging.exception("Błąd pobierania %s", jutro.isoformat())

    return biezace_i_jutrzejsze


# ------------------------------------------------
# EXCEL
# ------------------------------------------------

def generuj_excel(miesiac, rekordy):
    path = REPORTS / f"RCE_{miesiac}.xlsx"
    uporzadkowane = sorted(rekordy, key=lambda r: (r["data"], r.get("czas") or ""))
    ceny = [float(r["cena_pln_mwh"]) for r in uporzadkowane]
    if not ceny:
        raise ValueError(f"Brak cen do raportu za {miesiac}")

    wb = Workbook()
    ws = wb.active
    ws.title = "Ceny RCE"
    ws.append(["Data", "Godzina / okres", "Cena PLN/MWh", "Cena PLN/kWh"])
    for cell in ws[1]:
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = PatternFill("solid", fgColor="1F4E78")
        cell.alignment = Alignment(horizontal="center")

    for r in uporzadkowane:
        ws.append([r["data"], r.get("okres") or r.get("czas"),
                   r["cena_pln_mwh"], r["cena_pln_kwh"]])

    ws.freeze_panes = "A2"
    ws.auto_filter.ref = ws.dimensions
    for i, szerokosc in enumerate([15, 23, 20, 20], 1):
        ws.column_dimensions[get_column_letter(i)].width = szerokosc

    podsumowanie = wb.create_sheet("Podsumowanie")
    podsumowanie.append(["Parametr", "Wartość"])
    podsumowanie.append(["Miesiąc", miesiac])
    podsumowanie.append(["Liczba interwałów", len(ceny)])
    podsumowanie.append(["Średnia cena PLN/MWh", round(sum(ceny) / len(ceny), 3)])
    podsumowanie.append(["Minimum PLN/MWh", min(ceny)])
    podsumowanie.append(["Maksimum PLN/MWh", max(ceny)])
    for cell in podsumowanie[1]:
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = PatternFill("solid", fgColor="1F4E78")
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
        raise RuntimeError("Brak konfiguracji SMTP w pliku .env")

    msg = EmailMessage()
    msg["Subject"] = f"Raport miesięczny cen energii RCE – {miesiac}"
    msg["From"] = SMTP_USER
    msg["To"] = SMTP_TO
    msg.set_content(
        f"Raport miesięczny cen energii elektrycznej RCE.\n\n"
        f"Miesiąc: {miesiac}\nŹródło danych: PSE\nInterwał: 15 minut\n\n"
        "W załączeniu znajduje się raport Excel.\n"
        "Wiadomość wygenerowana automatycznie przez RCE-PSE.\n"
    )
    with open(plik, "rb") as f:
        msg.add_attachment(
            f.read(), maintype="application",
            subtype="vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            filename=plik.name,
        )

    context = ssl.create_default_context()
    with smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, context=context, timeout=40) as smtp:
        smtp.login(SMTP_USER, SMTP_PASSWORD)
        smtp.send_message(msg)
    logging.info("Raport %s wysłany na %s", miesiac, SMTP_TO)


def zamknij_miesiac(miesiac):
    pending_file = PENDING / f"{miesiac}.json"
    sent_file = SENT / f"{miesiac}.json"
    if sent_file.exists():
        return

    rekordy = odczytaj_json(pending_file)
    if not rekordy:
        return
    if not sprawdz_kompletnosc(miesiac, rekordy):
        logging.warning("Raport %s nie zostanie wysłany – brak kompletnych danych.", miesiac)
        return

    plik = None
    try:
        plik = generuj_excel(miesiac, rekordy)
        wyslij_email(miesiac, plik)
        # Znacznik zapisujemy po potwierdzeniu SMTP. Jeśli proces przerwie się
        # dokładnie po wysyłce, a przed znacznikiem, możliwa jest ponowna wysyłka.
        zapisz_json(sent_file, {
            "miesiac": miesiac,
            "wyslano": datetime.now(TZ).isoformat(),
            "odbiorca": SMTP_TO,
        })
        pending_file.unlink(missing_ok=True)
        plik.unlink(missing_ok=True)
        logging.info("Miesiąc %s zamknięty. Dane miesięczne usunięte.", miesiac)
    except Exception:
        logging.exception("Wysyłka/generowanie raportu %s nie powiodło się. Dane zachowane.", miesiac)


# ------------------------------------------------
# CZYSZCZENIE ARCHIWUM 30 DNI
# ------------------------------------------------

def czysc_archiwum(dzis=None):
    dzis = dzis or datetime.now(TZ).date()
    granica = dzis - timedelta(days=MAX_BACKFILL_DAYS - 1)
    for path in ARCHIVE.glob("*.json"):
        try:
            data = date.fromisoformat(path.stem)
            if data < granica:
                path.unlink()
                logging.info("Usunięto stare archiwum: %s", path.name)
        except ValueError:
            logging.warning("Nieprawidłowa nazwa archiwum: %s", path)


# ------------------------------------------------
# GŁÓWNA PĘTLA
# ------------------------------------------------

def wykonaj():
    dzis = datetime.now(TZ).date()
    wszystkie = uzupelnij_archiwum(dzis)
    zapisz_biezace(wszystkie)

    # Raport poprzedniego miesiąca sprawdzany jest w każdym cyklu.
    # Dane monthly_pending pozostają do skutecznej wysyłki.
    zamknij_miesiac(poprzedni_miesiac(dzis))
    czysc_archiwum(dzis)


if __name__ == "__main__":
    logging.info("Start RCE-PSE 2.1")
    while True:
        try:
            wykonaj()
        except Exception:
            logging.exception("Nieoczekiwany błąd kolektora")
        time.sleep(INTERVAL)
