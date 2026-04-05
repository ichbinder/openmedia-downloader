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
│ (callbacks)    │            │              │     │    (2 Server: Primary +  │
└──────────────┘             └──────────────┘     │     Backup)              │
                                                   │ 4. Post-Process:         │
                                                   │    → S3 Upload           │
                                                   │    → API Callback        │
                                                   └──────────────────────────┘
```

## SABnzbd Multi-Server Config

SABnzbd wird mit bis zu 2 Usenet-Servern konfiguriert:
- **Primary** (Priority 0): Bevorzugter Server (z.B. EasyUsenet/Abavia)
- **Backup** (Priority 1, optional): Fallback-Server (z.B. Eweka/Omicron)

Die Server-Config wird im `10-generate-config` Script generiert. Die komplette `[servers]`-Section wird als Ganzes geschrieben — SABnzbd 4.5.5 erfordert ein exaktes INI-Format mit allen Feldern (name, displayname, timeout, usage_at_start, notes, etc.), sonst werden Server-Blöcke still ignoriert.

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

### Primary Server (erforderlich)
| Variable | Beschreibung | Beispiel |
|----------|-------------|---------|
| `USENET_HOST` | Usenet Server | `reader.easyusenet.com` |
| `USENET_PORT` | Port (563 für SSL) | `563` |
| `USENET_USER` | Benutzername | `user` |
| `USENET_PASSWORD` | Passwort | `secret` |
| `USENET_SSL` | SSL (`1`/`0` oder `true`/`false`) | `1` |
| `USENET_CONNECTIONS` | Parallele Verbindungen | `10` |

### Backup Server (optional)
| Variable | Beschreibung | Beispiel |
|----------|-------------|---------|
| `USENET_BACKUP_HOST` | Backup Usenet Server | `news.eweka.nl` |
| `USENET_BACKUP_PORT` | Backup Port | `563` |
| `USENET_BACKUP_USER` | Backup Benutzername | `user2` |
| `USENET_BACKUP_PASSWORD` | Backup Passwort | `secret2` |
| `USENET_BACKUP_SSL` | Backup SSL | `1` |
| `USENET_BACKUP_CONNECTIONS` | Backup Verbindungen | `20` |

### Job & API
| Variable | Beschreibung |
|----------|-------------|
| `JOB_ID` | Download-Job ID |
| `JOB_HASH` | NZB-Hash (= Download-Name = S3-Key) |
| `NZB_URL` | URL zum openmedia-nzb Service |
| `API_BASE_URL` | openmedia-api URL (HTTPS in Produktion!) |
| `SERVICE_TOKEN` | Auth-Token für API-Callbacks |

### S3 Storage
| Variable | Beschreibung |
|----------|-------------|
| `S3_ACCESS_KEY` | Hetzner S3 Access Key |
| `S3_SECRET_KEY` | Hetzner S3 Secret Key |
| `S3_ENDPOINT` | S3 Endpoint URL |
| `S3_BUCKET` | Bucket Name |
| `S3_REGION` | Region (default: `hel1`) |

## Hash-Kette

Der Hash fließt lückenlos durch — kein extra API-Call nötig:

```
DB (NzbFile.hash) → ENV (JOB_HASH) → SABnzbd (nzbname) → SAB_FINAL_NAME → S3 Key
```

## SABnzbd INI-Format Hinweise

SABnzbd 4.5.5 ist streng beim Parsen der INI-Datei:
- **Alle Felder müssen vorhanden sein** (name, displayname, host, port, timeout, username, password, connections, ssl, ssl_verify, ssl_ciphers, enable, required, optional, retention, expire_date, quota, usage_at_start, priority, notes)
- **Leere Werte**: `""` (quoted empty string), nicht leer
- **ssl_verify**: `2` = Strict (empfohlen), `1` = Default/Minimal (bei Hostname-Mismatch)
- **Backup-Server**: `optional = 1`, `priority = 1`
- **fail_hopeless_jobs**: `1` = Sofort abbrechen wenn zu viele Segmente fehlen

## Deployment

Push zu `main` → GitHub Actions → Multi-Platform Docker Image auf GHCR:
- `ghcr.io/ichbinder/openmedia-downloader:latest`
- Plattformen: `linux/amd64` + `linux/arm64`

Die openmedia-api pulled das Image per Cloud-Init auf dem Hetzner Download-VPS.
