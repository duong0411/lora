# SATLO Mobile — cảnh báo sạt lở (Flutter)

App nhận MQTT từ gateway LoRa và bắn thông báo heads-up kiểu Shopee **kể cả khi vuốt tắt app**.

## Cách hoạt động khi tắt app

| Nền tảng | Cơ chế |
|---|---|
| **Android** | Foreground Service giữ MQTT WebSocket; alarm → local notification Importance.max + full-screen intent |
| **iOS** | Thông báo khi app nền / mở; kill hẳn process thì cần Apple Push (FCM) — bản này ưu tiên Android |

Luồng: `ESP32 node → LoRa → Gateway → MQTT alarm → App FG service → notification`

## Bật cảnh báo nền (Android — bắt buộc)

1. Đăng nhập + gắn Chip ID (`SATLO_GW01`)
2. Vào Home → nhấn **Thử thông báo + bật cảnh báo nền**
3. Cho phép: Thông báo, bỏ tối ưu pin, (nếu hỏi) báo thức chính xác
4. Kiểm tra khay thông báo có thanh **SATLO đang giám sát**
5. Vuốt tắt app → vẫn phải thấy thanh đó → khi gateway báo động sẽ popup như Shopee

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
