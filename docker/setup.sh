#!/usr/bin/env bash
set -euo pipefail
# -e = exit on error
# -u = treat unset variables as error
# -o pipefail = catch errors inside pipes

# Create an empty .env file to prevent "not found" error from docker-compose
touch .env

echo "▶️ Starting InfluxDB..."
sudo docker compose up -d influxdb3
echo "⏳ Waiting for InfluxDB..."
sleep 5

echo "▶️ Creating admin token..."
INFLUXDB_ADMIN_TOKEN=$(sudo docker compose exec -T influxdb3 influxdb3 create token --admin | grep "Token:" | awk '{print $2}') \
  || { echo "❌ Failed to create admin token"; exit 1; }
echo "INFLUXDB_TELEGRAF_TOKEN=${INFLUXDB_ADMIN_TOKEN}" >> .env
echo "✅ Admin token created."

echo "▶️ Starting Mosquitto and telegraf"
sudo docker compose up -d mosquitto telegraf explorer loki grafana

echo "Setting up firewall"
sudo ufw allow 22/tcp
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 8181,53,631,3000,22,1883,3389/tcp
sudo ufw enable
