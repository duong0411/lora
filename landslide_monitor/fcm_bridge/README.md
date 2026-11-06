# SATLO FCM Bridge — thông báo khi **tắt hẳn app**

MQTT trên điện thoại **không** đủ khi user Force Stop / máy giết process.  
FCM (như Facebook) do **Google** đẩy — app không cần chạy.

```
Gateway → MQTT alarm → [fcm_bridge] → FCM topic satlo_{CHIP} → điện thoại
```

## 1. Tạo Firebase (1 lần)

1. https://console.firebase.google.com → New project  
2. Add Android app, package: `com.duong0411.landslide.landslide_monitor`  
3. Tải `google-services.json` → đặt vào  
   `landslide_monitor/mobile/android/app/google-services.json`  
4. Project settings → Service accounts → Generate new private key  
   → lưu `serviceAccount.json` (bí mật, không commit)

## 2. Chạy bridge (VPS / máy luôn bật)

```bash
cd landslide_monitor/fcm_bridge
npm install
set GOOGLE_APPLICATION_CREDENTIALS=C:\path\serviceAccount.json
npm start
```

Linux:

```bash
export GOOGLE_APPLICATION_CREDENTIALS=/path/serviceAccount.json
npm start
```

Log khi có alarm:

```text
[MQTT] ALARM chip=SATLO_GW01 type=SAT_LO
[FCM] OK topic=satlo_SATLO_GW01 ...
```

## 3. App

Build lại APK sau khi có `google-services.json`.  
App tự `subscribeToTopic(satlo_{chip})` khi gắn Chip ID.

## Kiểm tra

1. App mở 1 lần (để subscribe topic) rồi **tắt hẳn** / Force Stop  
2. Gateway gửi alarm MQTT  
3. Bridge log FCM OK → điện thoại hiện banner (không cần mở app)
