# SATLO Mobile — cảnh báo sạt lở (Flutter)

## Thông báo khi **không mở / tắt app**

| Cách | Khi nào hiện | Hạn chế |
|------|----------------|---------|
| **FCM (Firebase)** ← đúng nhu cầu Facebook | App tắt, Force Stop, máy ngủ | Cần Firebase + chạy `fcm_bridge` |
| MQTT + Foreground Service | Vuốt Home, thanh “chạy nền” còn | Máy giết process → hết |

**Kết luận:** muốn chắc chắn có banner khi user không vào app → **bắt buộc FCM**.

Luồng FCM:

```text
Node LoRa → Gateway → MQTT alarm
        → fcm_bridge (server)
        → Firebase Cloud Messaging
        → Banner trên điện thoại (app không cần chạy)
```

Xem chi tiết: [`../fcm_bridge/README.md`](../fcm_bridge/README.md)

### Bật FCM trên app

1. Firebase Console → Android app package `com.duong0411.landslide.landslide_monitor`  
2. Copy `google-services.json` vào `android/app/`  
3. Build APK lại  
4. Chạy `fcm_bridge` với service account  
5. Mở app gắn Chip ID một lần (subscribe topic) → tắt app → test alarm  

Không có `google-services.json` thì app vẫn build (MQTT nền như cũ), FCM tự tắt.

## MQTT (telemetry khi app mở / FG còn sống)

- Broker: `wss://mqtt.duynguyen.io.vn/mqtt:443`
- Alarm: `tele/{CHIP}_alarm/status`

## Build

```bash
cd landslide_monitor/mobile
flutter pub get
flutter build apk --release
```

## GitHub Actions

```bash
git tag v1.0.22
git push origin v1.0.22
```
