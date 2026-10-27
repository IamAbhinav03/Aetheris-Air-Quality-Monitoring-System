# Aetheris air node firmware

The firmware is a single ESPHome configuration, [`fleet.yaml`](fleet.yaml), for
the whole fleet. You do **not** need one YAML file per device.

## How one binary serves many nodes

- `name_add_mac_suffix: true` makes ESPHome append the last 3 bytes of the
  MAC address at runtime, so the node names become `aetheris-1a2b3c`,
  `aetheris-4d5e6f`, and so on.
- The MQTT topic is built in a lambda:
  `airnode/<App.get_name()>/state` → `airnode/aetheris-1a2b3c/state`.
  Telegraf subscribes to `airnode/+/state` and extracts the name as the
  `device` tag, so every node appears automatically in Grafana.
- Wi-Fi, MQTT, API and OTA credentials are shared fleet-wide in
  `secrets.yaml`.

The display pages, PMS7003, SGP30, BME680 and SH1106 code are the same as in
[`AetherisNode.yaml`](AetherisNode.yaml), which remains as a single-node
example.

## 1. Configure credentials

From the repository root:

```bash
./scripts/setup.sh          # Linux / macOS / WSL
.\scripts\setup.ps1         # Windows
```

Or copy [`secrets.example.yaml`](secrets.example.yaml) to `secrets.yaml` and
fill it in. `secrets.yaml` is git-ignored.

Set `mqtt_broker` to the LAN IP of the machine running Docker Compose — not
`localhost`, because the air node connects to it over Wi-Fi.

## 2. Build once

```bash
./scripts/fleet.sh build
```

or, on Windows:

```powershell
.\scripts\fleet.ps1 build
```

Both scripts use a local `esphome` if it is installed, otherwise they run the
pinned `esphome/esphome:2026.10.0` Docker image.

When Docker is used, ESPHome's toolchain is kept in the
`aetheris-esphome-cache` Docker volume. The first build downloads the ESP-IDF
toolchain once (about 2-3 GB); later builds reuse it. Keeping it in a
volume also avoids slow or failing extractions on Windows bind mounts. Run the
`clean` command to delete it.

### Export the firmware binaries

If you build with Docker and want the `.bin` files for ESP Web Tools or a
manual flash, copy them out of the cache:

```bash
./scripts/fleet.sh firmware
```

```powershell
.\scripts\fleet.ps1 firmware
```

They are written to `AetherisSensorV1/firmware/`.

## 3. Flash the first node over USB

Every board needs the firmware once over USB. Use any of:

- ESPHome Dashboard → **Install** → plug in the board.
- A local ESPHome install:

  ```bash
  ./scripts/fleet.sh flash --port /dev/ttyACM0
  ```

  ```powershell
  .\scripts\fleet.ps1 flash -Port COM5
  ```

- ESP Web Tools with the compiled `firmware.factory.bin`.

Without Python or ESPHome installed, flash the exported factory image with the
standalone [esptool](https://github.com/espressif/esptool/releases) binary:

```powershell
.\esptool.exe --chip esp32c3 -p COM5 -b 460800 write_flash 0x0 firmware\firmware.factory.bin
```

A factory image contains the bootloader, partition table and app, so it always
goes to offset `0x0`. Later updates use `firmware.ota.bin` over Wi-Fi.

After the first boot the node joins the Wi-Fi from `secrets.yaml`. If it cannot,
it opens a fallback hotspot named `aetheris-xxxxxx` (password is
`wifi_ap_password`). Join it and open <http://192.168.4.1/> to enter Wi-Fi
details or upload new firmware.

Improv is enabled too:

- **USB** — `improv_serial` (works with the ESPHome web installer).
- **BLE** — `improv_ble` (ESP Web Tools / ESPHome app).

## 4. Update the rest of the fleet over Wi-Fi

Copy [`devices.example.csv`](devices.example.csv) to `devices.csv` and list
the IPs (or mDNS hostnames) of your nodes:

```csv
name,ip
classroom-101,192.168.1.101
classroom-102,192.168.1.102
```

Then deploy the already-compiled binary to every node:

```bash
./scripts/fleet.sh deploy --devices devices.csv
```

```powershell
.\scripts\fleet.ps1 deploy -DevicesFile devices.csv
```

A single node:

```bash
./scripts/fleet.sh deploy --device 192.168.1.101
```

The CSV `name` is just a label for the log output. The identity used by MQTT
and Grafana is the MAC-based device name (`aetheris-1a2b3c`).

## Notes

- `logger.hardware_uart: USB_SERIAL_JTAG` is required because the PMS7003
  uses GPIO20/21, which are UART0's default pins on the ESP32-C3. Logs and
  Improv go over the native USB port instead.
- The BLE stack uses RAM. If you see crashes on a C3, remove `improv_ble:` and
  keep `improv_serial:` + `captive_portal:`.
- Changing Wi-Fi for the whole fleet: edit `secrets.yaml`, rebuild, then
  `deploy`. For a single node, use the captive portal.
- The PMS7003 needs about a minute to spin up after a reset, so the first few
  `state` messages carry `null` for PM1.0/PM2.5/PM10. Those samples land in
  InfluxDB as gaps, which is expected.
- Don't watch the log with a plain serial terminal that asserts both DTR and
  RTS: on the C3 that combination holds the chip in download mode and the node
  stops sending. Use `esphome logs`, or if a terminal already did it, reset with
  `esptool.exe --chip esp32c3 -p COM5 --after hard-reset flash-id` or replug
  the board.
