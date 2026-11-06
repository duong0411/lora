import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'alert_store.dart';

/// Thông báo banner kiểu Facebook (tách khỏi thanh FGS chạy nền).
class SatloNotifications {
  SatloNotifications._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static int _id = 5000;

  /// Key native Android lắng nghe (SatloNativeAlerts.kt).
  static const nativePushKey = 'satlo_push_alert';

  static const _channelId = 'satlo_facebook_dart_v1';
  static const _channelName = 'Thông báo cảnh báo';
  static const _channelDesc =
      'Banner kiểu Facebook khi có lũ/sạt lở — kể cả tắt app';

  static bool get _isMobile {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  static Future<void> init({bool force = false}) async {
    if (!_isMobile) return;
    if (_ready && !force) return;

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
        requestCriticalPermission: false,
      ),
    );
    await _plugin.initialize(settings);

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDesc,
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        showBadge: true,
        enableLights: true,
        ledColor: Color(0xFFEE4D2D),
      ),
    );
    await android?.requestNotificationsPermission();
    try {
      await android?.requestFullScreenIntentPermission();
    } catch (_) {}

    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    await ios?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );

    _ready = true;
  }

  /// Đường chính khi tắt app: ghi prefs → native Kotlin bắn banner Facebook.
  static Future<void> _pushNativeAndroid({
    required String type,
    required String title,
    required String body,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      // Mỗi lần một nonce → listener luôn nhận thay đổi
      await prefs.setString(
        nativePushKey,
        jsonEncode({
          'type': type,
          'title': title,
          'body': body,
          'n': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('native push prefs: $e');
    }
  }

  static Future<void> showFloodAlert({
    required String type,
    required String title,
    required String body,
    bool force = false,
  }) async {
    if (!_isMobile) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force) {
      final last = await AlertStore.lastNotifyMs();
      if (now - last >= 0 && now - last < 10000) return;
    }

    final copy = _copyFor(type, title, body);

    // 1) Native Android banner (giống Facebook) — hoạt động khi app đã vuốt
    await _pushNativeAndroid(
      type: type,
      title: copy.title,
      body: copy.body,
    );

    // 2) Plugin Dart (khi app còn process / iOS)
    try {
      await init();
      final vibration = Int64List.fromList(
        type.toUpperCase() == 'SAT_LO'
            ? <int>[0, 500, 200, 500, 200, 800]
            : <int>[0, 400, 180, 400, 180, 400],
      );
      final details = NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.alarm,
          visibility: NotificationVisibility.public,
          fullScreenIntent: type.toUpperCase() == 'SAT_LO',
          playSound: true,
          enableVibration: true,
          vibrationPattern: vibration,
          ticker: copy.title,
          icon: '@mipmap/ic_launcher',
          color: const Color(0xFFEE4D2D),
          colorized: true,
          autoCancel: true,
          ongoing: false,
          onlyAlertOnce: false,
          showWhen: true,
          when: now,
          styleInformation: BigTextStyleInformation(
            copy.body,
            contentTitle: copy.title,
            summaryText: 'SATLO',
          ),
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentList: true,
          presentSound: true,
          presentBadge: true,
          interruptionLevel: InterruptionLevel.timeSensitive,
          subtitle: copy.subtitle,
        ),
      );
      await _plugin.show(
        _id++,
        copy.title,
        copy.body,
        details,
        payload: type,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('local notif: $e');
    }

    await AlertStore.markNotified();
  }

  static Future<void> show({required String title, required String body}) {
    return showFloodAlert(type: 'ALERT', title: title, body: body);
  }

  static ({String title, String body, String subtitle}) _copyFor(
    String type,
    String title,
    String body,
  ) {
    switch (type.toUpperCase()) {
      case 'WET_RISK':
        return (
          title: title.trim().isEmpty ? '⚠️ Cảnh báo nguy cơ lũ!' : title,
          body: body.trim().isEmpty
              ? 'Lượng mưa / mực nước và độ ẩm đất đang cao. Kiểm tra ngay.'
              : body,
          subtitle: 'Nguy cơ lũ',
        );
      case 'SAT_LO':
        return (
          title: title.trim().isEmpty ? '🚨 Cảnh báo sạt lở!' : title,
          body: body.trim().isEmpty
              ? 'Phát hiện rung/nghiêng kèm ẩm cao. Nguy hiểm — kiểm tra khu vực.'
              : body,
          subtitle: 'Sạt lở',
        );
      case 'IMPACT':
        return (
          title: title.trim().isEmpty ? '⚠️ Cảnh báo rung lắc' : title,
          body: body.trim().isEmpty
              ? 'IMU phát hiện va đập / rung mạnh.'
              : body,
          subtitle: 'Rung lắc',
        );
      case 'TILT':
        return (
          title: title.trim().isEmpty ? '⚠️ Cảnh báo nghiêng' : title,
          body: body.trim().isEmpty ? 'Góc nghiêng vượt ngưỡng an toàn.' : body,
          subtitle: 'Nghiêng',
        );
      case 'TEST':
        return (
          title: title.trim().isEmpty ? '✅ Thử thông báo SATLO' : title,
          body: body.trim().isEmpty
              ? 'Đây là thông báo kiểu Facebook — tắt app vẫn hiện được.'
              : body,
          subtitle: 'Kiểm tra',
        );
      default:
        return (
          title: title.trim().isEmpty ? '⚠️ Cảnh báo SATLO' : title,
          body: body.trim().isEmpty ? 'Gateway đang báo động.' : body,
          subtitle: 'Cảnh báo',
        );
    }
  }
}
