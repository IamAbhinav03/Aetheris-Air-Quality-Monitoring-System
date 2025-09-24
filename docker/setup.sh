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
echo "✅ Admin token created."

# echo "▶️ Creating bucket 'metrics'..."
# sudo docker compose exec -T influxdb influxdb3 create bucket metrics \
#   --token "${INFLUXDB_ADMIN_TOKEN}" || { echo "❌ Failed to create bucket"; exit 1; }
# echo "✅ Bucket 'metrics' created."

echo "▶️ Starting Mosquitto and telegraf"
sudo docker compose up -d mosquitto telegraf
