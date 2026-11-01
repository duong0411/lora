import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'notifications.dart';

/// Giữ MQTT khi vuốt/tắt app — bắn thông báo heads-up kiểu Shopee khi có alarm.
class BackgroundMonitor {
  BackgroundMonitor._();

  static bool get _mobile {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  static void configure() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'satlo_fg_watch',
        channelName: 'Giám sát sạt lở',
        channelDescription:
            'Giữ kết nối để báo lũ/sạt lở khi không mở app',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        enableVibration: false,
        playSound: false,
        onlyAlertOnce: true,
        visibility: NotificationVisibility.VISIBILITY_PUBLIC,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(15000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
        allowAutoRestart: true,
        stopWithTask: false,
      ),
    );
  }

  static Future<void> sync({required bool enabled}) async {
    if (!_mobile) return;
    try {
      if (!enabled) {
        if (await FlutterForegroundTask.isRunningService) {
          await FlutterForegroundTask.stopService();
        }
        return;
      }

      await SatloNotifications.init();
      await FlutterForegroundTask.requestNotificationPermission();

      if (await FlutterForegroundTask.isRunningService) {
        FlutterForegroundTask.sendDataToTask(AppConfig.chipId);
        return;
      }

      final result = await FlutterForegroundTask.startService(
        serviceId: 791,
        serviceTypes: const [ForegroundServiceTypes.remoteMessaging],
        notificationTitle: 'SATLO đang giám sát',
        notificationText: 'Sẽ báo khi có nguy cơ lũ / sạt lở',
        callback: satloBackgroundCallback,
      );
      if (result is ServiceRequestFailure && kDebugMode) {
        debugPrint('BackgroundMonitor start: ${result.error}');
      }

      final ignoring =
          await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      if (!ignoring) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    } catch (e, st) {
      if (kDebugMode) debugPrint('BackgroundMonitor.sync: $e\n$st');
    }
  }
}

@pragma('vm:entry-point')
void satloBackgroundCallback() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(SatloBackgroundHandler());
}

class SatloBackgroundHandler extends TaskHandler {
  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _sub;
  bool _busy = false;
  String _chip = AppConfig.defaultChipId;
  String? _lastAlarmKey;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await SatloNotifications.init();
    await _openMqtt(force: true);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    final c = _client;
    if (c == null ||
        c.connectionStatus?.state != MqttConnectionState.connected) {
      unawaited(_openMqtt(force: false));
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _sub?.cancel();
    _sub = null;
    try {
      _client?.disconnect();
    } catch (_) {}
    _client = null;
  }

  @override
  void onReceiveData(Object data) {
    final next = data.toString().trim();
    if (next.isEmpty || next == _chip) return;
    _chip = next;
    unawaited(_openMqtt(force: true));
  }

  Future<void> _openMqtt({required bool force}) async {
    if (_busy) return;
    final connected =
        _client?.connectionStatus?.state == MqttConnectionState.connected;
    if (!force && connected) return;
    _busy = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final saved = prefs.getString('satlo_chip_id');
      _chip = (saved == null || saved.trim().isEmpty)
          ? _chip
          : saved.trim();
      AppConfig.setChipId(_chip);

      await _sub?.cancel();
      try {
        _client?.disconnect();
      } catch (_) {}

      final cid =
          'satlo-bg-${DateTime.now().millisecondsSinceEpoch}';
      final c = MqttServerClient.withPort(
        AppConfig.brokerUrl,
        cid,
        AppConfig.brokerPort,
      );
      c.useWebSocket = true;
      c.secure = false;
      c.websocketProtocols = MqttClientConstants.protocolsSingleDefault;
      c.logging(on: false);
      c.keepAlivePeriod = 30;
      c.autoReconnect = true;
      c.resubscribeOnAutoReconnect = true;
      c.connectionMessage =
          MqttConnectMessage().withClientIdentifier(cid).startClean();

      await c.connect().timeout(const Duration(seconds: 12));
      if (c.connectionStatus?.state != MqttConnectionState.connected) {
        await FlutterForegroundTask.updateService(
          notificationTitle: 'SATLO đang giám sát',
          notificationText: 'Chưa nối MQTT $_chip — đang thử lại',
        );
        return;
      }

      // Chỉ cần alarm + online để cảnh báo nền
      c.subscribe(AppConfig.topicAlarm, MqttQos.atMostOnce);
      c.subscribe(AppConfig.topicOnline, MqttQos.atMostOnce);
      c.subscribe(AppConfig.topicWater, MqttQos.atMostOnce);
      c.subscribe(AppConfig.topicSoil, MqttQos.atMostOnce);

      _sub = c.updates?.listen((events) {
        for (final e in events) {
          final rec = e.payload as MqttPublishMessage;
          final payload =
              MqttPublishPayload.bytesToStringAsString(rec.payload.message);
          unawaited(_onMessage(e.topic, payload));
        }
      });

      _client = c;
      await FlutterForegroundTask.updateService(
        notificationTitle: 'SATLO đang giám sát',
        notificationText: 'Máy $_chip — báo khi có lũ / sạt lở',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('SatloBackgroundHandler: $e');
      await FlutterForegroundTask.updateService(
        notificationTitle: 'SATLO đang giám sát',
        notificationText: 'Mất kết nối — đang thử lại',
      );
    } finally {
      _busy = false;
    }
  }

  Future<void> _onMessage(String topic, String payload) async {
    if (topic != AppConfig.topicAlarm) return;
    try {
      final j = jsonDecode(payload);
      if (j is! Map) return;
      final value = '${j['value'] ?? ''}'.toUpperCase();
      if (value != 'ON') {
        _lastAlarmKey = null;
        return;
      }
      final type = '${j['type'] ?? 'ALERT'}';
      final title = _titleFor(type);
      final body = _bodyFor(type, j);
      final key = '$type|$title|$body';
      if (key == _lastAlarmKey) return;
      _lastAlarmKey = key;

      await SatloNotifications.showFloodAlert(
        type: type,
        title: title,
        body: body,
      );
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: body,
      );
    } catch (_) {
      await SatloNotifications.showFloodAlert(
        type: 'ALERT',
        title: '⚠️ Cảnh báo SATLO',
        body: payload,
      );
    }
  }

  String _titleFor(String type) {
    switch (type.toUpperCase()) {
      case 'WET_RISK':
        return '⚠️ Cảnh báo nguy cơ lũ!';
      case 'SAT_LO':
        return '🚨 Cảnh báo sạt lở!';
      case 'IMPACT':
        return '⚠️ Cảnh báo rung lắc';
      case 'TILT':
        return '⚠️ Cảnh báo nghiêng';
      default:
        return '⚠️ Cảnh báo SATLO';
    }
  }

  String _bodyFor(String type, Map j) {
    final w = j['water'];
    final s = j['soil'];
    final metrics =
        (w != null || s != null) ? ' · Mưa ${w ?? '--'}% · Đất ${s ?? '--'}%' : '';
    switch (type.toUpperCase()) {
      case 'WET_RISK':
        return 'Lượng mưa và độ ẩm đất cao — nguy cơ ngập/lũ.$metrics';
      case 'SAT_LO':
        return 'Rung/nghiêng + ẩm/nước cao — kiểm tra ngay.$metrics';
      case 'IMPACT':
        return 'IMU phát hiện va đập / rung mạnh.';
      case 'TILT':
        return 'Góc nghiêng vượt ngưỡng an toàn.';
      default:
        return 'Gateway đang báo động.$metrics';
    }
  }
}
