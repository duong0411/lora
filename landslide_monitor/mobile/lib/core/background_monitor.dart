import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

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
        channelId: 'satlo_fg_watch_v2',
        channelName: 'Giám sát sạt lở (nền)',
        channelDescription:
            'Thanh thông báo giữ kết nối MQTT khi tắt app',
        channelImportance: NotificationChannelImportance.DEFAULT,
        priority: NotificationPriority.DEFAULT,
        enableVibration: false,
        playSound: false,
        onlyAlertOnce: true,
        visibility: NotificationVisibility.VISIBILITY_PUBLIC,
        showWhen: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(12000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
        allowAutoRestart: true,
        stopWithTask: false,
      ),
    );
  }

  static Future<bool> isRunning() async {
    if (!_mobile) return false;
    try {
      return await FlutterForegroundTask.isRunningService;
    } catch (_) {
      return false;
    }
  }

  /// Bật/tắt dịch vụ nền. Gọi khi đã có UI (Home/Connect) để xin quyền được.
  static Future<bool> sync({
    required bool enabled,
    bool showTestAlert = false,
  }) async {
    if (!_mobile) return false;
    try {
      if (!enabled) {
        if (await FlutterForegroundTask.isRunningService) {
          await FlutterForegroundTask.stopService();
        }
        return true;
      }

      await SatloNotifications.init();

      // Android 13+: bắt buộc cho cả FG notification + alert
      final notifPerm =
          await FlutterForegroundTask.checkNotificationPermission();
      if (notifPerm != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      await FlutterForegroundTask.requestNotificationPermission();

      if (Platform.isAndroid) {
        final ignoring =
            await FlutterForegroundTask.isIgnoringBatteryOptimizations;
        if (!ignoring) {
          await FlutterForegroundTask.requestIgnoreBatteryOptimization();
        }
        // Giữ service sống khi reboot / bị hệ thống kill
        try {
          if (!await FlutterForegroundTask.canScheduleExactAlarms) {
            await FlutterForegroundTask.openAlarmsAndRemindersSettings();
          }
        } catch (_) {}
      }

      if (await FlutterForegroundTask.isRunningService) {
        FlutterForegroundTask.sendDataToTask(AppConfig.chipId);
        if (showTestAlert) {
          await SatloNotifications.showFloodAlert(
            type: 'TEST',
            title: '✅ Cảnh báo nền đã bật',
            body:
                'Vuốt tắt app vẫn nhận cảnh báo lũ/sạt lở. Chip ${AppConfig.chipId}',
          );
        }
        return true;
      }

      final result = await FlutterForegroundTask.startService(
        serviceId: 791,
        serviceTypes: const [ForegroundServiceTypes.remoteMessaging],
        notificationTitle: 'SATLO đang giám sát',
        notificationText:
            'Chip ${AppConfig.chipId} — báo khi có lũ / sạt lở (tắt app vẫn chạy)',
        callback: satloBackgroundCallback,
      );

      final ok = result is! ServiceRequestFailure;
      if (!ok && kDebugMode) {
        debugPrint('BackgroundMonitor start: $result');
      }

      if (ok && showTestAlert) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await SatloNotifications.showFloodAlert(
          type: 'TEST',
          title: '✅ Cảnh báo nền đã bật',
          body:
              'Vuốt tắt app vẫn nhận cảnh báo. Hãy để thanh “SATLO đang giám sát” trên thông báo.',
        );
      }
      return ok;
    } catch (e, st) {
      if (kDebugMode) debugPrint('BackgroundMonitor.sync: $e\n$st');
      return false;
    }
  }
}

@pragma('vm:entry-point')
void satloBackgroundCallback() {
  DartPluginRegistrant.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(SatloBackgroundHandler());
}

class SatloBackgroundHandler extends TaskHandler {
  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _sub;
  bool _busy = false;
  String _chip = AppConfig.defaultChipId;
  String? _lastAlarmKey;
  double? _water;
  double? _soil;
  double? _roll;
  double? _pitch;
  bool _wetLatched = false;
  bool _tiltLatched = false;
  static const double _tiltDegThreshold = 25;

  String get _alarmTopic => 'tele/${_chip}_alarm/status';
  String get _waterTopic => 'tele/${_chip}_water/status';
  String get _soilTopic => 'tele/${_chip}_soil/status';
  String get _rollTopic => 'tele/${_chip}_roll/status';
  String get _pitchTopic => 'tele/${_chip}_pitch/status';

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Cho engine/plugin kịp gắn channel trong isolate service
    await Future<void>.delayed(const Duration(milliseconds: 800));
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
          ? (_chip.isEmpty ? AppConfig.defaultChipId : _chip)
          : saved.trim();
      AppConfig.setChipId(_chip);

      await _sub?.cancel();
      try {
        _client?.disconnect();
      } catch (_) {}
      _client = null;

      final cid = 'satlo-bg-${DateTime.now().millisecondsSinceEpoch}';
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
      c.onConnected = () {
        c.subscribe(_alarmTopic, MqttQos.atLeastOnce);
        c.subscribe(_waterTopic, MqttQos.atMostOnce);
        c.subscribe(_soilTopic, MqttQos.atMostOnce);
        c.subscribe(_rollTopic, MqttQos.atMostOnce);
        c.subscribe(_pitchTopic, MqttQos.atMostOnce);
      };
      c.connectionMessage =
          MqttConnectMessage().withClientIdentifier(cid).startClean();

      await c.connect().timeout(const Duration(seconds: 15));
      if (c.connectionStatus?.state != MqttConnectionState.connected) {
        await FlutterForegroundTask.updateService(
          notificationTitle: 'SATLO đang giám sát',
          notificationText: 'Chưa nối MQTT $_chip — đang thử lại',
        );
        return;
      }

      c.subscribe(_alarmTopic, MqttQos.atLeastOnce);
      c.subscribe(_waterTopic, MqttQos.atMostOnce);
      c.subscribe(_soilTopic, MqttQos.atMostOnce);
      c.subscribe(_rollTopic, MqttQos.atMostOnce);
      c.subscribe(_pitchTopic, MqttQos.atMostOnce);

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
        notificationText: 'Máy $_chip online — tắt app vẫn báo động',
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

  dynamic _valueOf(String payload) {
    final p = payload.trim();
    try {
      final j = jsonDecode(p);
      if (j is Map && j.containsKey('value')) return j['value'];
      return j;
    } catch (_) {
      return p;
    }
  }

  Future<void> _onMessage(String topic, String payload) async {
    if (topic == _waterTopic) {
      final v = _valueOf(payload);
      if (v is num) _water = v.toDouble();
      await _maybeWetFromTelemetry();
      return;
    }
    if (topic == _soilTopic) {
      final v = _valueOf(payload);
      if (v is num) _soil = v.toDouble();
      await _maybeWetFromTelemetry();
      return;
    }
    if (topic == _rollTopic) {
      final v = _valueOf(payload);
      if (v is num) _roll = v.toDouble();
      await _maybeTiltFromTelemetry();
      return;
    }
    if (topic == _pitchTopic) {
      final v = _valueOf(payload);
      if (v is num) _pitch = v.toDouble();
      await _maybeTiltFromTelemetry();
      return;
    }
    if (topic != _alarmTopic) return;

    try {
      final j = jsonDecode(payload);
      if (j is! Map) return;
      final value = '${j['value'] ?? ''}'.toUpperCase();
      if (value != 'ON') {
        _lastAlarmKey = null;
        _tiltLatched = false;
        _wetLatched = false;
        return;
      }
      final type = '${j['type'] ?? 'ALERT'}';
      final t = type.toUpperCase();
      if (t == 'TILT') _tiltLatched = true;
      if (t == 'WET_RISK') _wetLatched = true;
      await _fireAlert(
        type: type,
        title: _titleFor(type),
        body: _bodyFor(type, j),
      );
    } catch (_) {
      await _fireAlert(
        type: 'ALERT',
        title: '⚠️ Cảnh báo SATLO',
        body: payload,
      );
    }
  }

  /// Dự phòng: nếu gateway chưa publish alarm nhưng water/soil cao vẫn báo.
  Future<void> _maybeWetFromTelemetry() async {
    final w = _water ?? 0;
    final s = _soil ?? 0;
    final hot = w >= 35 || s >= 70;
    if (!hot) {
      _wetLatched = false;
      return;
    }
    if (_wetLatched) return;
    _wetLatched = true;
    await _fireAlert(
      type: 'WET_RISK',
      title: '⚠️ Cảnh báo nguy cơ lũ!',
      body: 'Lượng mưa ${w.toStringAsFixed(0)}% · Đất ${s.toStringAsFixed(0)}% — kiểm tra ngay.',
    );
  }

  /// OLED NGHIENG nhưng miss topic alarm → vẫn báo từ roll/pitch.
  Future<void> _maybeTiltFromTelemetry() async {
    final r = (_roll ?? 0).abs();
    final p = (_pitch ?? 0).abs();
    final hot = r >= _tiltDegThreshold || p >= _tiltDegThreshold;
    if (!hot) {
      _tiltLatched = false;
      return;
    }
    if (_tiltLatched) return;
    _tiltLatched = true;
    await _fireAlert(
      type: 'TILT',
      title: '⚠️ Cảnh báo nghiêng',
      body:
          'Góc nghiêng R ${r.toStringAsFixed(0)}° · P ${p.toStringAsFixed(0)}° — kiểm tra ngay.',
    );
  }

  Future<void> _fireAlert({
    required String type,
    required String title,
    required String body,
  }) async {
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
