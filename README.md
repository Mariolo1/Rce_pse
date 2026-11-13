# RCE-PSE

An automated collector for RCE (Market Energy Price) data published by Polskie Sieci Elektroenergetyczne (PSE), the Polish Transmission System Operator. The application retrieves data from the PSE API, stores it locally, backfills missing days from historical data, and prepares and emails an Excel report at the end of each month.

> This project is designed to collect, archive, and report energy prices. It does not control an inverter, an energy storage system, or any other equipment.

## Key features

- Retrieves RCE prices from the PSE API: `https://api.raporty.pse.pl/api/rce-pln`.
- Retrieves data for the current day and attempts to retrieve next-day data when it is available through the API.
- Runs an automatic collection cycle every 15 minutes.
- Backfills historical data for the last 30 days.
- Also backfills the entire previous month until the report for that month is marked as sent.
- Merges records and removes duplicates using the date, time, and period as the record key.
- Checks daily data completeness, accounting for daylight saving time in the `Europe/Warsaw` time zone (a day may contain 92, 96, or 100 intervals).
- Stores data in JSON files.
- Generates a monthly Excel workbook containing interval records and a summary.
- Sends the report by email using SMTP over SSL.
- Deletes daily archive files older than 30 days. Data awaiting a monthly report is stored separately.

## Requirements

- Docker Engine
- Docker Compose (`docker compose` plugin)
- Network access to the PSE API
- An email account with SMTP access, if automatic report delivery is required

The application runs in a Python 3.12-based container, as specified by the project's Docker image configuration.

## Project structure

```text
rce-pse/
├── app.py                 # main collector application
├── Dockerfile             # builds the application image
├── docker-compose.yml     # runs the container
├── requirements.txt       # Python dependencies
├── .env.example           # SMTP configuration template (no secrets)
├── .gitignore             # files excluded from Git
├── .dockerignore          # files excluded from the Docker image
├── install-rce.sh         # installation script, if used
├── update-rce.sh          # update script, if used
└── data/                  # persistent data mounted into the container; not stored in Git
    ├── current/            # latest operational data set
    ├── archive/            # daily JSON archive (30-day retention)
    ├── monthly_pending/    # monthly data awaiting report delivery
    ├── reports/            # temporary Excel reports
    └── sent/                # markers for reports that have been sent
```

## Installation and startup

1. Clone the repository:

   ```bash
   git clone https://github.com/Mariolo1/Rce_pse.git
   cd Rce_pse
   ```

2. Create a local configuration file from the example template:

   ```bash
   cp .env.example .env
   nano .env
   ```

3. Set the SMTP options in `.env` (see the section below).

4. Build the image and start the application:

   ```bash
   docker compose up -d --build
   ```

5. Check the container status and logs:

   ```bash
   docker compose ps
   docker compose logs -f rce-pse
   ```

The container can be configured to restart automatically (`unless-stopped`, if set in `docker-compose.yml`). Data is stored on the host in the `./data` directory, not only inside the container.

## SMTP email configuration

Example `.env.example` file:

```dotenv
SMTP_HOST=poczta.interia.pl
SMTP_PORT=465
SMTP_USER=your_address@interia.pl
SMTP_PASSWORD=ENTER_YOUR_PASSWORD_HERE
SMTP_TO=recipient_address@interia.pl
```

Variable descriptions:

| Variable | Description |
|---|---|
| `SMTP_HOST` | SMTP server address; defaults to `poczta.interia.pl` |
| `SMTP_PORT` | SMTP SSL port; defaults to `465` |
| `SMTP_USER` | Sender mailbox login/address |
| `SMTP_PASSWORD` | Password or app password required by the email provider |
| `SMTP_TO` | Recipient address for reports |

For Interia, make sure the account allows access from an external email client and that the correct login credentials are used.

**Security:** the real `.env` file contains confidential information. Do not commit it or publish it. Only add `.env.example` to the repository, using sample values that are not real credentials. Do not put passwords in source code, logs, or issue reports.

## How the collector works

1. The application determines which dates to check: the last 30 days and, if its report has not yet been marked as sent, every day of the previous month.
2. For historical dates, it checks the local archive. Complete days are not unnecessarily downloaded again; missing or incomplete days are retrieved from the PSE API.
3. Retrieved data is merged with local records. A newer record replaces an earlier record with the same key (`date`, `time`, `period`).
4. Current-day data is refreshed, and the application attempts to retrieve next-day data. The availability of next-day prices depends on publication by PSE.
5. Once data for the previous month has been collected, the application checks whether every day is complete.
6. If the month is complete, the application generates an Excel workbook and emails it.
7. After successful email submission, it writes a marker to `sent/` and removes the data from `monthly_pending/` and the temporary report. If report generation or email delivery fails, the monthly data is retained for the next attempt.

The collector runs every 15 minutes. It checks the previous month's report on successive cycles until the report has been sent.

## Data files

| Path | Contents |
|---|---|
| `data/current/rce.json` | Latest operational data set: current-day data and any retrieved next-day data |
| `data/archive/YYYY-MM-DD.json` | Daily price archive |
| `data/monthly_pending/YYYY-MM.json` | Collected monthly data awaiting a complete report |
| `data/reports/RCE_YYYY-MM.xlsx` | Temporary Excel workbook prepared for delivery |
| `data/sent/YYYY-MM.json` | Marker confirming that the report has been sent |

The `data/` directory contains the application's persistent state. Do not delete it during an update or without making a backup first.

## Excel report

The monthly report contains two worksheets:

- **RCE Prices** — date, time/period, price in PLN/MWh, and price in PLN/kWh.
- **Summary** — month, number of intervals, average price, minimum price, and maximum price in PLN/MWh.

The report is sent only after the completeness check passes. Day length is calculated using the `Europe/Warsaw` time zone, accounting for daylight saving time changes.

## Useful Docker commands

```bash
# Build/update the image and start the container
docker compose up -d --build

# Service status
docker compose ps

# Follow application logs
docker compose logs -f rce-pse

# Show the last 100 log lines
docker compose logs --tail=100 rce-pse

# Restart the container
docker compose restart rce-pse

# Stop the application
docker compose down
```

`docker compose down` stops and removes the Compose container and network resources. With the standard bind mount `./data:/data`, it does not delete the data directory on the host. Do not use the `-v` option unless you are certain which volumes are attached.

## Updating

After pulling changes from the repository:

```bash
git pull
docker compose up -d --build
```

Before updating, it is recommended to back up the `data/` directory and the local `.env` file. Do not overwrite `.env` with the example file.

## Limitations and notes

- Report completeness depends on the availability and quality of the data published by PSE.
- Missing next-day data does not necessarily indicate a failure; prices may not have been published yet.
- Historical backfilling covers the last 30 days and the entire previous month until the report is marked as sent. This is not an unlimited historical archive.
- Successful SMTP submission means the email server accepted the message; it does not guarantee that the message reaches the recipient's Inbox rather than the Spam folder.
- The project currently does not include control of energy equipment or any guarantee of energy cost optimisation.

## Data sources

- PSE RCE API: <https://api.raporty.pse.pl/api/rce-pln>
- PSE reporting portal: <https://raporty.pse.pl/>

## License

No project license has been specified yet. Until a `LICENSE` file is added, do not assume that the repository is available under an open-source license that permits unrestricted use, modification, or redistribution.
