# openmedia-downloader

SABnzbd-basierter Download-Container für openmedia. Lädt NZB-Dateien via Usenet herunter, uploaded die Mediendatei hash-basiert nach Hetzner S3, und meldet den Abschluss an die openmedia-API.

## Architektur

```
openmedia-api                          Hetzner VPS (on-demand)
┌──────────────┐    Cloud-Init    ┌──────────────────────────────┐
│ POST /provision │──────────────►│ docker run openmedia-downloader│
│ (creates VPS)  │               │                                │
│                │◄──────────────│ 1. sabnzbd.ini generieren      │
│ PATCH /status  │   callback    │ 2. SABnzbd starten             │
│ (completed)    │               │ 3. NZB submitten (hash=name)   │
│                │               │ 4. Post-Process:               │
└──────────────┘               │    → S3 Upload als hash/hash.ext│
                                │    → API Callback               │
                                │ 5. VPS signalisiert: "lösch mich"│
                                └──────────────────────────────────┘
```

## Environment Variables

| Variable | Beschreibung | Beispiel |
|----------|-------------|---------|
| `JOB_ID` | Download-Job ID aus der API | `abc-123-def` |
| `JOB_HASH` | Hash der NZB-Datei (wird als Download-Name verwendet) | `a7f3c2b1d4e5...` |
| `NZB_URL` | URL zum Herunterladen der NZB-Datei | `https://api.example.com/nzb/files/xyz/raw` |
| `API_BASE_URL` | openmedia-api Base URL | `https://api.example.com` |
| `SERVICE_TOKEN` | Auth-Token für API-Callbacks | `eyJ...` |
| `USENET_HOST` | Usenet Server Hostname | `news.example.com` |
| `USENET_PORT` | Usenet Server Port | `563` |
| `USENET_USER` | Usenet Benutzername | `myuser` |
| `USENET_PASSWORD` | Usenet Passwort | `secret` |
| `USENET_SSL` | SSL verwenden | `1` |
| `USENET_CONNECTIONS` | Anzahl Verbindungen | `10` |
| `S3_ACCESS_KEY` | Hetzner S3 Access Key | `AKIA...` |
| `S3_SECRET_KEY` | Hetzner S3 Secret Key | `wJal...` |
| `S3_ENDPOINT` | Hetzner S3 Endpoint | `https://hel1.your-objectstorage.com` |
| `S3_BUCKET` | S3 Bucket Name | `openmedia-files` |
| `S3_REGION` | S3 Region | `hel1` |

## Hash-Kette

Der NzbFile.hash fließt lückenlos durch das System:

1. **DB**: NzbFile.hash = `a7f3c2...`
2. **ENV**: `JOB_HASH=a7f3c2...` → an VPS übergeben
3. **SABnzbd API**: `nzbname=a7f3c2...` → Job heißt so
4. **Post-Processing**: `SAB_FINAL_NAME=a7f3c2...` → Script liest Hash
5. **S3**: `a7f3c2.../a7f3c2...mkv` → Hash-basierter Pfad

Keine extra API-Anfrage nötig um den Hash zu ermitteln.

## Lokale Entwicklung

```bash
cp .env.example .env
# .env ausfüllen
docker compose up
```

## Deployment

Docker Image wird per GitHub Release → GitHub Actions → GHCR gebaut.
Cloud-Init auf dem Hetzner VPS zieht das Image und startet es mit den ENV-Variablen.
