# Aetheris — Air Quality Monitoring System

Aetheris is an open-source air-quality monitoring platform built around the
**Aetheris Sensor**, a compact ESP32-C3 node that measures particulate matter,
CO₂, TVOCs, temperature and humidity.

This repository contains everything needed to run a complete monitoring
network: the Docker Compose stack (MQTT → time-series database → dashboards),
log aggregation, and one ESPHome firmware for an entire fleet of nodes.

```
┌──────────────┐   MQTT    ┌────────────┐        ┌─────────────┐   SQL    ┌──────────┐
│  Air nodes   │──────────▶│ Mosquitto  │───────▶│ InfluxDB 3  │─────────▶│ Grafana  │
│  ESP32-C3    │  airnode/  │  2.1.2     │Telegraf│    Core     │          │ 13.2.4   │
│  ESPHome     │  <id>/state└────────────┘ 1.40.2└─────────────┘          └────▲─────┘
└──────────────┘                                                               │
                                       container logs ┌────────┐   ┌────────┐   │
                                       ──────────────▶│ Alloy  │──▶│  Loki  │───┘
                                                      │ 1.21.2 │   │ 3.7.9  │
                                                      └────────┘   └────────┘
```

## What is included

| Component          | Version            | Purpose                                              |
| ------------------ | ------------------ | ---------------------------------------------------- |
| Grafana            | `13.2.4`           | Dashboards and log exploration                       |
| Grafana Loki       | `3.7.9`            | Log storage                                          |
| Grafana Alloy      | `1.21.2`           | Collects Docker container logs and ships them to Loki |
| Telegraf           | `1.40.2`           | MQTT → InfluxDB bridge                               |
| InfluxDB 3 Core    | `3.12.1-core`      | Time-series database (SQL / FlightSQL)               |
| InfluxDB 3 Explorer| `1.11.1` (optional)| Database admin UI                                    |
| Eclipse Mosquitto  | `2.1.2-alpine`     | MQTT broker with authentication                      |
| Portainer CE       | `2.45.3` (optional)| Container management UI                              |
| ESPHome            | `2026.10.0`        | Air-node firmware                                    |

Data is stored in named Docker volumes, images are pinned, and only Grafana
and MQTT are reachable from other machines by default.

## Quick start

Requirements: Docker with the Compose plugin (Docker Desktop, Docker Engine,
or Podman with the Docker Compose provider) and roughly 10 GB of free disk
space for images, volumes and logs.

```bash
git clone https://github.com/IamAbhinav03/Aetheris-Air-Quality-Monitoring-System.git
cd Aetheris-Air-Quality-Monitoring-System

# Linux / macOS / WSL
./scripts/setup.sh

# Windows PowerShell
.\scripts\setup.ps1

docker compose up -d
```

`setup` generates `.env` with random passwords, creates the Mosquitto password
file, and writes `AetherisSensorV1/secrets.yaml` with your Wi-Fi and MQTT
details. It prints the generated credentials when it finishes.

Open **<http://localhost:3000>** and sign in with the Grafana user/password
printed by the setup script. Two dashboards are provisioned automatically:

- **Aetheris · Air Quality** — gauges, trends and a per-node selector.
- **Aetheris · Logs** — container logs and log volume, from Loki.

## Ports

| Service   | Host binding        | Notes                                  |
| --------- | ------------------- | -------------------------------------- |
| Grafana   | `0.0.0.0:3000`      | Public UI                              |
| Mosquitto | `0.0.0.0:1883`      | Air nodes connect here (auth required) |
| InfluxDB  | `127.0.0.1:8181`    | Admin only, not exposed to the network |
| Loki      | `127.0.0.1:3100`    | Admin only                             |
| Alloy     | `127.0.0.1:12345`   | Admin/debug only                       |
| Explorer  | `127.0.0.1:8888`    | `--profile admin`                      |
| Portainer | `127.0.0.1:9000`    | `--profile admin`                      |

Change ports in `.env`. To run the optional admin tools:

```bash
docker compose --profile admin up -d
```

## Air nodes

The firmware is a **single ESPHome configuration** for the whole fleet:
[`AetherisSensorV1/fleet.yaml`](AetherisSensorV1/fleet.yaml).

- Every board gets the same binary.
- `name_add_mac_suffix: true` gives each node a unique runtime name, e.g.
  `aetheris-1a2b3c`.
- The node publishes to `airnode/aetheris-1a2b3c/state`.
- Telegraf turns the topic into a `device` tag, and Grafana discovers it
  automatically — no per-device YAML and no dashboard edits.

```bash
# 1. Put Wi-Fi + MQTT details in secrets.yaml (setup scripts do this)
# 2. Build once
./scripts/fleet.sh build

# 3. Flash the first board over USB
./scripts/fleet.sh flash --port /dev/ttyACM0

# 4. Copy the example inventory and deploy the same build over Wi-Fi
cp AetherisSensorV1/devices.example.csv devices.csv
./scripts/fleet.sh deploy --devices devices.csv

# Optional: copy firmware.factory.bin out of the Docker cache for ESP Web Tools
./scripts/fleet.sh firmware
```

Windows equivalents and the full workflow (captive portal, Improv, adding
nodes) are in [`AetherisSensorV1/README.md`](AetherisSensorV1/README.md).

## Data model

MQTT payload (published every 15 s):

```json
{
  "pm1": 4.2,
  "pm25": 6.1,
  "pm10": 8.0,
  "eco2": 512,
  "tvoc": 73,
  "temperature": 24.6,
  "humidity": 48.2,
  "wifi_dbm": -58
}
```

Telegraf writes the `air_quality` measurement in the `aetheris` database with
the tags `topic` and `device`. Grafana queries it with InfluxDB 3 SQL, e.g.:

```sql
SELECT $__dateBin(time) AS time, avg(pm25) AS "PM2.5"
FROM air_quality
WHERE $__timeFilter(time) AND device = 'aetheris-1a2b3c'
GROUP BY $__dateBin(time)
ORDER BY time
```

## Logs

Alloy discovers every container through the Docker socket, reads its
stdout/stderr, adds `container`, `service`, `project` and `stream` labels, and
writes to Loki (`http://loki:3100`). Open **Aetheris · Logs** in Grafana, or use
Explore with the Loki datasource.

> **Docker Desktop note (Windows/macOS):** Alloy reads logs through the Docker
> socket, so log collection works on Docker Desktop as well as on Linux. The
> trade-off is that Alloy needs read access to `/var/run/docker.sock`; only
> run this stack on a host you trust.

## Configuration

All runtime settings live in `.env` (see [`.env.example`](.env.example)):

| Variable                 | Description                              |
| ------------------------ | ---------------------------------------- |
| `TZ`                     | Container timezone                       |
| `GRAFANA_ADMIN_USER`     | Grafana admin user                       |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin password                   |
| `MQTT_USERNAME`          | MQTT username (also used by air nodes)   |
| `MQTT_PASSWORD`          | MQTT password (also used by air nodes)   |
| `GRAFANA_PORT`           | Host port for Grafana                    |
| `MQTT_PORT`              | Host port for MQTT                       |
| `*_PORT`                 | Admin-only ports                         |

The ESPHome credentials are in `AetherisSensorV1/secrets.yaml`. Both files are
git-ignored. Re-run `setup --force` only if you intentionally want to rotate
everything (it overwrites credentials).

## Operations

```bash
# Status / logs
docker compose ps
docker compose logs -f telegraf

# Update to newer pinned images
docker compose pull
docker compose up -d

# Stop (data is kept in named volumes)
docker compose down

# Stop and delete all data
docker compose down -v
```

### Backup

Named volumes are prefixed with the Compose project name (`aetheris_`):

```bash
mkdir -p backups

docker run --rm \
  -v aetheris_influxdb3-data:/data:ro \
  -v "$PWD/backups:/backup" \
  alpine tar czf /backup/influxdb3.tar.gz -C /data .

docker run --rm \
  -v aetheris_grafana-data:/data:ro \
  -v "$PWD/backups:/backup" \
  alpine tar czf /backup/grafana.tar.gz -C /data .

docker run --rm \
  -v aetheris_loki-data:/data:ro \
  -v "$PWD/backups:/backup" \
  alpine tar czf /backup/loki.tar.gz -C /data .
```

Restore by running the same commands with the source and destination reversed
(`tar xzf`).

### Changing MQTT credentials

1. Edit `MQTT_USERNAME` / `MQTT_PASSWORD` in `.env`.
2. Regenerate the broker password file:
   ```bash
   ./scripts/setup.sh --force   # or: docker compose down && ./scripts/setup.sh
   ```
   (Use `-Force` on Windows. This also regenerates the ESPHome secrets file,
   so update the air nodes afterwards.)
3. `docker compose up -d mosquitto telegraf`
4. Rebuild and redeploy the firmware.

## Security notes

- Mosquitto requires authentication; anonymous access is disabled.
- InfluxDB 3 Core runs with `--without-auth` **only** on the private Docker
  network. Its port is bound to `127.0.0.1`, so it is not reachable from other
  machines. If you expose it, enable authentication and set a token in
  `telegraf.conf` and the Grafana datasource.
- Grafana anonymous access and sign-ups are disabled.
- `.env`, `secrets.yaml` and the Mosquitto password file are git-ignored.
- For internet-facing deployments, put Grafana behind a TLS reverse proxy and
  restrict port `1883` to your sensor network.
- MQTT is plain TCP. Enable Mosquitto TLS before sending credentials over an
  untrusted network.

## Repository layout

```
compose.yaml                  # the whole stack
.env.example                  # configuration template
scripts/
  setup.sh / setup.ps1        # generate .env, MQTT password, ESPHome secrets
  fleet.sh / fleet.ps1        # build / flash / OTA-deploy the fleet / export .bin
grafana/
  provisioning/               # datasources + dashboard provider
  dashboards/                 # provisioned dashboards
telegraf/telegraf.conf        # MQTT → InfluxDB 3
loki/loki-config.yaml
alloy/alloy-config.alloy      # Docker logs → Loki
mosquitto/config/             # broker config (+ generated passwd)
AetherisSensorV1/
  fleet.yaml                  # ONE firmware for the whole fleet
  AetherisNode.yaml           # single-node reference config
  secrets.example.yaml
  devices.example.csv
```

## Troubleshooting

| Symptom | Fix |
| ------- | --- |
| Mosquitto exits with a `passwd` error | Run `./scripts/setup.sh` to generate `mosquitto/config/passwd`. |
| Mosquitto `Permission denied` on the passwd file | `chmod 644 mosquitto/config/passwd` (the hash file only needs to be readable). |
| Telegraf logs `database not found` | Wait for `aetheris-influxdb-init` to finish: `docker compose logs influxdb-init`. |
| Grafana shows no data | Check `docker compose logs telegraf`; confirm nodes are publishing to `airnode/<id>/state`. |
| No logs in Loki | Check `docker compose logs alloy`; confirm `/var/run/docker.sock` is mounted. |
| Air node stuck on Wi-Fi | Join the `aetheris-xxxxxx` hotspot (password in `secrets.yaml`) and open <http://192.168.4.1/>. |
| ESPHome build fails on `!secret` | Run the setup script, or copy `secrets.example.yaml` to `secrets.yaml`. |
| Docker Desktop reports `unable to start` or `read-only file system` | Free disk space on the host, then restart Docker Desktop. A full disk makes the Docker VM read-only. |
| Grafana login fails with "unknown error occurred" | Restart Docker Desktop. After a WSL restart its port relay can keep accepting connections on port 3000 and then drop them, which the login form reports as a generic error. |
| Panels show "No data" with a red error icon | Hover the icon for the real message. If you edited a dashboard file, note that the home dashboard (`/d/dashboard-home-dashboard/`) is a copy loaded when Grafana starts, so it keeps the old queries until `docker compose restart grafana`. The provisioned dashboard at `/d/aetheris-air-quality/` updates within 30 seconds. |

## License

No license file is included yet. Contact the maintainer before redistributing.
