#!/usr/bin/env/ bash
set -euo pipefail
# -e = exit on error
# -u  treat unset variables as error
# -o pipefaile = catch errors inside pipes

# Helper: run command inside influxb container with admin token
run_influx() {
  docker compose exec -T -e INFLUXDB_TOKEN=$ADMIN_TOKEN influxdb3 "$@" || {
    echo "❌ Failed: influxdb3 $*"
    exit 1
  }
}

echo "▶️  Starting InfluxDB..."
docker compose up -d influxdb3
echo "⏳ Waiting for InfluxDB..."
sleep 5

echo "▶️ Creating admin token..."
ADMIN_TOKEN=$(docker compose exec -T influxdb3 influxdb3 create token --admin -o json | jq -r '.token') \
  || { echo "❌ Failed to create admin token"; exit 1; }

echo "▶️ Creating bucket 'metrics'..."
run_influx influxdb3 create bucket metrics

echo "▶️ Creating write token for Telegraf..."
TELEGRAF_TOKEN=$(run_influx influxdb3 create token --write-bucket metrics -o json | jq -r '.token')

echo "▶️ Creating read token for Grafana..."
GRAFANA_TOKEN=$(run_influx influxdb3 create token --read-bucket metrics -o json | jq -r '.token')

echo "▶️ Writing tokens to .env..."
cat > .env <<EOF
INFLUXDB_TELEGRAF_TOKEN=${TELEGRAF_TOKEN}
INFLUXDB_GRAFANA_TOKEN=${GRAFANA_TOKEN}
EOF

echo "✅ Tokens saved to .env"
echo "   Telegraf has WRITE access only."
echo "   Grafana has READ access only."

echo "▶️ Starting Telegraf and Grafana..."
docker compose up -d telegraf grafana

