# SATLO Mobile — cảnh báo sạt lở (Flutter)

App nhận MQTT từ gateway LoRa và bắn thông báo heads-up kiểu Shopee **kể cả khi vuốt tắt app**.

## Cách hoạt động khi tắt app

| Nền tảng | Cơ chế |
|---|---|
| **Android** | Foreground Service giữ MQTT WebSocket; alarm → local notification Importance.max + full-screen intent |
| **iOS** | Thông báo khi app nền / mở; kill hẳn process thì cần Apple Push (FCM) — bản này ưu tiên Android |

Luồng: `ESP32 node → LoRa → Gateway → MQTT alarm → App FG service → notification`

## Cảnh báo nền (Android — tự chạy)

App **tự bật** giám sát nền khi đăng nhập / vào Home — **không cần** bấm nút thử.
Nút “Thử popup” chỉ để kiểm tra âm thanh/banner; cảnh báo thật chỉ hiện khi gateway gửi alarm.

1. Đăng nhập + gắn Chip ID (`SATLO_GW01`)
2. Lần đầu: cho phép **Thông báo** + **bỏ tối ưu pin** (hệ thống hỏi)
3. Kiểm tra khay thông báo có thanh **SATLO đang giám sát**
4. Vuốt tắt app → thanh đó vẫn còn → khi gateway báo động sẽ popup như Shopee

Máy Xiaomi / Oppo / Vivo / Huawei: thêm app vào **tự khởi động** + **không hạn chế pin**.

## MQTT

- Broker: `wss://mqtt.duynguyen.io.vn/mqtt:443`
- Alarm: `tele/{CHIP}_alarm/status` → `{"value":"ON","type":"SAT_LO",...}`

## Build local

```bash
cd landslide_monitor/mobile
flutter pub get
flutter build apk --release
# iOS (macOS):
flutter build ios --release --no-codesign
```

## GitHub Actions → APK + IPA

Workflow: `.github/workflows/mobile-release.yml`

```bash
git tag v1.0.7
git push origin v1.0.7
```

Hoặc **Actions → Mobile Release → Run workflow**.

Artifacts lên **Releases**:
- `landslide_monitor-android.apk`
- `landslide_monitor-ios-unsigned.ipa`
