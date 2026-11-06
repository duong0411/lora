import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Lưu alarm đang ON — UI và isolate nền cùng đọc/ghi.
/// Fix: tắt app sau khi báo trong app → nền vẫn biết để bắn heads-up lại.
class ActiveAlert {
  final String type;
  final String title;
  final String body;
  final int updatedMs;

  const ActiveAlert({
    required this.type,
    required this.title,
    required this.body,
    required this.updatedMs,
  });

  Map<String, dynamic> toJson() => {
        'type': type,
        'title': title,
        'body': body,
        'updatedMs': updatedMs,
      };

  factory ActiveAlert.fromJson(Map<String, dynamic> j) => ActiveAlert(
        type: '${j['type'] ?? 'ALERT'}',
        title: '${j['title'] ?? '⚠️ Cảnh báo SATLO'}',
        body: '${j['body'] ?? ''}',
        updatedMs: (j['updatedMs'] as num?)?.toInt() ?? 0,
      );
}

class AlertStore {
  AlertStore._();

  static const _key = 'satlo_active_alarm_v1';
  static const _lastNotifyKey = 'satlo_active_alarm_last_notify_ms';

  static Future<void> setActive({
    required String type,
    required String title,
    required String body,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final a = ActiveAlert(
      type: type,
      title: title,
      body: body,
      updatedMs: DateTime.now().millisecondsSinceEpoch,
    );
    await prefs.setString(_key, jsonEncode(a.toJson()));
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    await prefs.remove(_key);
  }

  static Future<ActiveAlert?> read() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      return ActiveAlert.fromJson(Map<String, dynamic>.from(j));
    } catch (_) {
      return null;
    }
  }

  static Future<int> lastNotifyMs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getInt(_lastNotifyKey) ?? 0;
  }

  static Future<void> markNotified() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _lastNotifyKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }
}
