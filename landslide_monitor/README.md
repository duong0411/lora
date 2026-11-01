# Landslide Monitor — đồng bộ MQTT với iot_class

Đã chỉnh lại cho **đúng chuẩn lớp học thông minh** (`C:\Users\Duong Phung\Downloads\iot_class`).

## MQTT đúng (như SmartHome_ESP32 / Flutter app lớp học)

| Mục | Giá trị |
|---|---|
| Host | `mqtt.duynguyen.io.vn` |
| Port | `443` |
| Path | `/mqtt` |
| Kiểu | **WSS** (WebSocket SSL) |
| ESP32 lib | `WebSockets` + `MQTTPubSubClient` |
| App | `MqttServerClient` + `useWebSocket=true` |

> Bản trước dùng nhầm `mqtt.duynguyen.io:1883` (TCP) — **không khớp** broker của bạn. Đã sửa.

## Topic (kiểu tele/.../status như lớp học)

Chip mặc định: `SATLO_GW01`

| Topic | Ý nghĩa |
|---|---|
| `tele/SATLO_GW01/status` | `online` / `offline` |
| `tele/SATLO_GW01_water/status` | `{"value":90.5}` |
| `tele/SATLO_GW01_soil/status` | `{"value":100}` |
| `tele/SATLO_GW01_roll/status` | IMU roll |
| `tele/SATLO_GW01_pitch/status` | IMU pitch |
| `tele/SATLO_GW01_lora/status` | `ONLINE` / `OFFLINE` |
| `tele/SATLO_GW01_alarm/status` | `{"value":"ON","type":"SAT_LO",...}` → app notification |

## Firmware

- Gateway: `gateway/gateway.ino`
- Edge node: `../lora_esp32_node/lora_esp32_node.ino`

### Thư viện gateway (Arduino)
1. LoRa  
2. Adafruit SSD1306 + GFX  
3. WiFiManager  
4. **WebSockets** (Markus Sattler)  
5. **MQTTPubSubClient** (Hideaki Tai)  

### WiFi portal (bàn giao)
- AP: `SATLO-Gateway-Setup` / `12345678`
- Đổi WiFi sau: giữ **BOOT 3 giây**

## App mobile
`mobile/` — kết nối `wss://mqtt.duynguyen.io.vn/mqtt:443`, Chip ID = `SATLO_GW01`
