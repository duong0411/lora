# lora — Giám sát sạt lở (ESP32 LoRa + Gateway + Mobile)

Repo: https://github.com/duong0411/lora

## Cấu trúc

| Thư mục | Mô tả |
|---|---|
| `lora_esp32_node/` | Firmware edge node (cảm biến + LoRa TX) |
| `landslide_monitor/gateway/` | Firmware gateway (LoRa RX + OLED + còi + WiFi portal + MQTT WSS) |
| `landslide_monitor/mobile/` | App Flutter cảnh báo điện thoại |
| `lora_sx1278_test/` | Test LoRa TX |
| `lora_sx1278_rx_test/` | Test LoRa RX |

## MQTT (chuẩn iot_class)

- Broker: `wss://mqtt.duynguyen.io.vn/mqtt` (port 443)
- Chip ID mặc định: `SATLO_GW01`
- Alarm topic: `tele/SATLO_GW01_alarm/status`

## Mobile Release (GitHub Actions)

Workflow: `.github/workflows/mobile-release.yml`

### Cách tạo bản APK + IPA

**Cách 1 — tạo tag:**
```bash
git tag v1.0.0
git push origin v1.0.0
```

**Cách 2 — Actions → Mobile Release → Run workflow**

Artifacts lên **GitHub Releases**:
- `landslide_monitor-android.apk`
- `landslide_monitor-ios-unsigned.ipa` (IPA chưa ký — cần Apple cert để cài máy thật)

## Gateway WiFi portal

- AP: `SATLO-Gateway-Setup` / `12345678`
- Giữ BOOT 3 giây để mở lại portal (không cần nạp firmware)
