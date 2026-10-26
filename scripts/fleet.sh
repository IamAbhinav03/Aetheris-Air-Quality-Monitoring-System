#!/usr/bin/env bash
# =============================================================================
# Aetheris fleet firmware helper (Linux / macOS / WSL)
# =============================================================================
#   ./scripts/fleet.sh build
#   ./scripts/fleet.sh config
#   ./scripts/fleet.sh deploy --devices devices.csv
#   ./scripts/fleet.sh deploy --device 192.168.1.50
#   ./scripts/fleet.sh flash --port /dev/ttyACM0
#
# The first USB flash must be done on a machine that can see the serial port.
# After that, `deploy` updates every node over Wi-Fi (OTA) using one compiled
# binary. Wi-Fi/MQTT credentials come from AetherisSensorV1/secrets.yaml
# (created by scripts/setup.sh).
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SENSOR_DIR="$ROOT/AetherisSensorV1"
CONFIG_FILE="fleet.yaml"
ESPHOME_IMAGE="${ESPHOME_IMAGE:-esphome/esphome:2026.10.0}"

COMMAND="${1:-build}"
shift || true

DEVICE=""
DEVICES_FILE="devices.csv"
PORT=""
SKIP_BUILD=0

while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="${2:-}"; shift 2 ;;
    --devices) DEVICES_FILE="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

run_esphome() {
  if command -v esphome >/dev/null 2>&1; then
    ( cd "$SENSOR_DIR" && esphome "$@" )
    return $?
  fi

  echo "    using Docker image $ESPHOME_IMAGE"
  docker run --rm \
    -v "$SENSOR_DIR:/config" \
    -w /config \
    "$ESPHOME_IMAGE" "$@"
}

assert_files() {
  [ -f "$SENSOR_DIR/$CONFIG_FILE" ] || { echo "Missing $CONFIG_FILE in $SENSOR_DIR" >&2; exit 1; }
  [ -f "$SENSOR_DIR/secrets.yaml" ] || {
    echo "Missing AetherisSensorV1/secrets.yaml. Run ./scripts/setup.sh first." >&2
    exit 1
  }
}

echo "==> Aetheris fleet: $COMMAND"

case "$COMMAND" in
  build)
    assert_files
    run_esphome compile "$CONFIG_FILE"
    ;;

  config)
    assert_files
    run_esphome config "$CONFIG_FILE"
    ;;

  flash)
    assert_files
    [ -n "$PORT" ] || { echo "Pass --port /dev/ttyACM0" >&2; exit 1; }
    if ! command -v esphome >/dev/null 2>&1; then
      echo "USB flashing needs a local ESPHome install (Docker cannot access serial ports)." >&2
      echo "Install it with: pipx install esphome" >&2
      exit 1
    fi
    run_esphome run "$CONFIG_FILE" --device "$PORT" --no-logs
    ;;

  clean)
    rm -rf "$SENSOR_DIR/build" "$SENSOR_DIR/.esphome/build"
    echo "    removed the ESPHome build directory"
    ;;

  deploy)
    assert_files

    if [ -n "$DEVICE" ]; then
      IPS="$DEVICE"
      COUNT=1
    else
      case "$DEVICES_FILE" in
        /*) CSV="$DEVICES_FILE" ;;
        *) CSV="$ROOT/$DEVICES_FILE" ;;
      esac
      [ -f "$CSV" ] || {
        echo "Devices file not found: $CSV" >&2
        echo "Copy AetherisSensorV1/devices.example.csv and fill in your nodes." >&2
        exit 1
      }
      IPS="$(awk -F, 'NR>1 && $2 != "" { gsub(/[[:space:]]/, "", $2); print $2 }' "$CSV")"
      COUNT="$(printf '%s\n' "$IPS" | grep -c . || true)"
    fi

    [ "$COUNT" -gt 0 ] || { echo "No devices to deploy to." >&2; exit 1; }

    if [ "$SKIP_BUILD" -eq 0 ]; then
      echo "    compiling once for the whole fleet..."
      run_esphome compile "$CONFIG_FILE"
    fi

    FAILED=""
    INDEX=0
    for IP in $IPS; do
      INDEX=$((INDEX + 1))
      echo ""
      echo "[$INDEX/$COUNT] $IP"

      OK=0
      for ATTEMPT in 1 2; do
        if [ "$ATTEMPT" -gt 1 ]; then
          echo "    retrying (attempt $ATTEMPT)..."
          sleep 3
        fi
        if run_esphome upload "$CONFIG_FILE" --device "$IP"; then
          OK=1
          break
        fi
      done

      [ "$OK" -eq 1 ] || FAILED="$FAILED $IP"
    done

    echo ""
    if [ -n "$FAILED" ]; then
      echo "==> Failed devices:$FAILED" >&2
      exit 1
    fi
    echo "==> All $COUNT device(s) updated"
    ;;

  *)
    echo "Unknown command: $COMMAND" >&2
    echo "Use: build | config | deploy | flash | clean" >&2
    exit 1
    ;;
esac
