import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'alert_store.dart';

/// Heads-up kiểu Shopee — kênh MAX, hoạt động khi tắt app (qua FG service).
class SatloNotifications {
  SatloNotifications._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static int _id = 5000;

  /// Channel mới — Android không nâng Importance của channel cũ.
  static const _channelId = 'satlo_flood_v4';
  static const _channelName = 'Cảnh báo lũ & sạt lở';
  static const _channelDesc =
      'Thông báo khẩn khi lũ/sạt lở — kể cả khi tắt app';

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

  /// Hiển thị cảnh báo — [force] bỏ qua chốt chống spam ngắn.
  static Future<void> showFloodAlert({
    required String type,
    required String title,
    required String body,
    bool force = false,
  }) async {
    if (!_isMobile) return;
    await init();

    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force) {
      final last = await AlertStore.lastNotifyMs();
      // Chống spam cùng phiên ~12s khi app đang mở
      if (now - last >= 0 && now - last < 12000) return;
    }

    final copy = _copyFor(type, title, body);
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
        fullScreenIntent: true,
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
          summaryText: 'SATLO · Cảnh báo khẩn',
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
          title: title.trim().isEmpty ? '✅ Cảnh báo nền đã bật' : title,
          body: body.trim().isEmpty
              ? 'Vuốt tắt app vẫn nhận cảnh báo lũ/sạt lở.'
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
