# openmedia-downloader

SABnzbd-basierter Download-Container für openmedia. Lädt NZB-Dateien via Usenet herunter, uploaded die Mediendatei hash-basiert nach Hetzner S3, und meldet den Abschluss an die openmedia-API.

## Architektur

```
openmedia-api                openmedia-nzb              Hetzner VPS (on-demand)
┌──────────────┐             ┌──────────────┐     ┌──────────────────────────┐
│ POST /provision│            │ GET /nzb/{hash}│   │ openmedia-downloader     │
│ (creates VPS) │            │ (Proxmox)    │     │                          │
│                │            │              │     │ 1. sabnzbd.ini generieren│
│                │            │              │◄────│ 2. NZB holen per URL     │
│ PATCH /status  │◄───────────│              │     │ 3. SABnzbd lädt herunter │
│ (callbacks)    │            │              │     │ 4. Post-Process:         │
└──────────────┘             └──────────────┘     │    → S3 Upload           │
                                                   │    → API Callback        │
                                                   └──────────────────────────┘
```

**Wichtig:** Der Container holt die NZB-Datei direkt vom `openmedia-nzb` Service — nicht von der Main API. Die API baut nur die URL zusammen.

## Docker Image Aufbau

```
linuxserver/sabnzbd:latest          (Base Image)
├── /etc/cont-init.d/
│   └── 10-generate-config          s6 Init: generiert sabnzbd.ini aus ENV
├── /config/scripts/
│   └── post-process.sh             SABnzbd Post-Processing: S3 Upload + API Callback
├── /opt/openmedia/
│   ├── templates/sabnzbd.ini.template
│   └── submit-and-monitor.sh       NZB Submit + Progress Monitoring
└── awscli, curl, bash              Tools für S3 + API
```

## Environment Variables

| Variable | Beschreibung | Beispiel |
|----------|-------------|---------|
| `JOB_ID` | Download-Job ID | `abc-123-def` |
| `JOB_HASH` | NZB-Hash (= Download-Name = S3-Key) | `4532860a...` |
| `NZB_URL` | URL zum openmedia-nzb Service | `https://nzb.example.com/nzb/4532860a...` |
| `API_BASE_URL` | openmedia-api URL (HTTPS in Produktion!) | `https://api.example.com` |
| `SERVICE_TOKEN` | Auth-Token für API-Callbacks | `eyJ...` |
| `USENET_HOST` | Usenet Server | `news.newshosting.com` |
| `USENET_PORT` | Port (563 für SSL) | `563` |
| `USENET_USER` | Benutzername | `user` |
| `USENET_PASSWORD` | Passwort | `secret` |
| `USENET_SSL` | SSL (`1`/`0` oder `true`/`false`) | `1` |
| `USENET_CONNECTIONS` | Parallele Verbindungen | `10` |
| `S3_ACCESS_KEY` | Hetzner S3 Access Key | `2SC7...` |
| `S3_SECRET_KEY` | Hetzner S3 Secret Key | `wJal...` |
| `S3_ENDPOINT` | S3 Endpoint | `https://hel1.your-objectstorage.com` |
| `S3_BUCKET` | Bucket Name | `openmedia-files` |
| `S3_REGION` | Region | `hel1` |

## Hash-Kette

Der Hash fließt lückenlos durch — kein extra API-Call nötig:

```
DB (NzbFile.hash) → ENV (JOB_HASH) → SABnzbd (nzbname) → SAB_FINAL_NAME → S3 Key
```

## Security

- **Keine Secrets im Docker Image** — nur Templates mit Platzhaltern
- **ENV-File statt -e Flags** — Credentials nicht in `/proc/cmdline` sichtbar
- **API_BASE_URL MUSS HTTPS sein** in Produktion (Bearer Token Schutz)
- **Env-File wird nach Lesen gelöscht** (`rm -f` in post-process.sh)
- **S3 Upload über HTTPS** (Hetzner S3 Endpoint)
- **VPS ist kurzlebig** — wird nach Download gelöscht, alle Daten weg

## Lokale Entwicklung

```bash
cp .env.example .env
# .env ausfüllen
docker compose up
```

## Deployment

GitHub Release → GitHub Actions → Docker Image auf GHCR (`ghcr.io/ichbinder/openmedia-downloader`).
Cloud-Init auf Hetzner VPS pulled das Image und startet es mit `--env-file`.
