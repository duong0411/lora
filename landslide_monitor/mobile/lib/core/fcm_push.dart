import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'config.dart';
import 'notifications.dart';

/// FCM — thông báo khi app đã tắt / Force Stop (kiểu Facebook).
/// Cần google-services.json + fcm_bridge đang chạy.
@pragma('vm:entry-point')
Future<void> satloFirebaseBackgroundHandler(RemoteMessage message) async {
  // Payload có "notification" → hệ thống tự hiện banner khi app killed.
  // Data-only: hiện local.
  try {
    await Firebase.initializeApp();
  } catch (_) {}
  final n = message.notification;
  if (n == null) {
    final type = message.data['type'] ?? 'ALERT';
    final title = message.data['title'] ?? '⚠️ Cảnh báo SATLO';
    final body = message.data['body'] ?? 'Gateway đang báo động.';
    await SatloNotifications.showFloodAlert(
      type: type,
      title: title,
      body: body,
      force: true,
    );
  }
}

class FcmPush {
  FcmPush._();

  static bool ready = false;
  static String? _subscribedTopic;

  static String topicFor(String chip) {
    final c = chip.trim().isEmpty ? AppConfig.defaultChipId : chip.trim();
    return 'satlo_${c.replaceAll(RegExp(r'[^a-zA-Z0-9\-_.~%]'), '_')}';
  }

  static Future<void> init() async {
    if (kIsWeb) return;
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(satloFirebaseBackgroundHandler);

      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        criticalAlert: false,
      );

      // Channel FCM Android (khớp fcm_bridge channelId)
      if (Platform.isAndroid) {
        const ch = AndroidNotificationChannel(
          'satlo_fcm_v1',
          'Cảnh báo FCM',
          description: 'Push khi tắt app — qua Firebase Cloud Messaging',
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
        );
        await FlutterLocalNotificationsPlugin()
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.createNotificationChannel(ch);
      }

      FirebaseMessaging.onMessage.listen((m) async {
        final n = m.notification;
        final title = n?.title ?? m.data['title'] ?? '⚠️ Cảnh báo SATLO';
        final body = n?.body ?? m.data['body'] ?? 'Gateway đang báo động.';
        final type = m.data['type'] ?? 'ALERT';
        await SatloNotifications.showFloodAlert(
          type: type,
          title: title,
          body: body,
          force: true,
        );
      });

      ready = true;
      if (kDebugMode) {
        final t = await messaging.getToken();
        debugPrint('[FCM] ready token=${t?.substring(0, 12)}...');
      }

      if (AppConfig.chipId.isNotEmpty) {
        await subscribeChip(AppConfig.chipId);
      }
    } catch (e) {
      ready = false;
      if (kDebugMode) {
        debugPrint(
          '[FCM] chưa bật (thiếu google-services.json / Firebase): $e',
        );
      }
    }
  }

  static Future<void> subscribeChip(String chipId) async {
    if (!ready) return;
    final topic = topicFor(chipId);
    try {
      final messaging = FirebaseMessaging.instance;
      if (_subscribedTopic != null && _subscribedTopic != topic) {
        await messaging.unsubscribeFromTopic(_subscribedTopic!);
      }
      await messaging.subscribeToTopic(topic);
      _subscribedTopic = topic;
      if (kDebugMode) debugPrint('[FCM] subscribe $topic');
    } catch (e) {
      if (kDebugMode) debugPrint('[FCM] subscribe fail: $e');
    }
  }

  static Future<void> unsubscribe() async {
    if (!ready || _subscribedTopic == null) return;
    try {
      await FirebaseMessaging.instance
          .unsubscribeFromTopic(_subscribedTopic!);
      _subscribedTopic = null;
    } catch (_) {}
  }
}
