import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class SatloNotifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static int _id = 3000;

  static Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
    );
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        'satlo_alerts',
        'Cảnh báo sạt lở',
        description: 'Thông báo khi gateway/còi cảnh báo',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );
  }

  static Future<void> show({required String title, required String body}) async {
    const android = AndroidNotificationDetails(
      'satlo_alerts',
      'Cảnh báo sạt lở',
      channelDescription: 'Thông báo khi gateway/còi cảnh báo',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.alarm,
      playSound: true,
      enableVibration: true,
      color: Color(0xFFE07A3D),
    );
    const ios = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    await _plugin.show(
      _id++,
      title,
      body,
      const NotificationDetails(android: android, iOS: ios),
    );
  }
}
