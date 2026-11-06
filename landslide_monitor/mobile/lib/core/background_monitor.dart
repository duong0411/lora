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
        channelId: 'satlo_fg_watch_v3',
        channelName: 'Giám sát sạt lở (nền)',
        channelDescription:
            'Thanh thông báo giữ kết nối MQTT khi tắt app — đừng tắt thanh này',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
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
        // Ping MQTT / reconnect thường xuyên hơn
        eventAction: ForegroundTaskEventAction.repeat(5000),
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

  /// App đang mở (UI tự hiện cảnh báo) → BG không spam trùng.
  static void setAppForeground(bool foreground) {
    if (!_mobile) return;
    try {
      FlutterForegroundTask.sendDataToTask(
        foreground ? 'APP_FG' : 'APP_BG',
      );
    } catch (_) {}
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
            force: true,
          );
        }
        return true;
      }

      final result = await FlutterForegroundTask.startService(
        serviceId: 791,
        serviceTypes: const [ForegroundServiceTypes.remoteMessaging],
        notificationTitle: 'SATLO đang giám sát',
        notificationText:
            'Chip ${AppConfig.chipId} — tắt app vẫn báo động (giữ thanh này)',
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
              'Vuốt tắt app vẫn nhận cảnh báo. Giữ thanh “SATLO đang giám sát”.',
          force: true,
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
  // false mặc định: vuốt/tắt app thường không kịp gửi APP_BG → vẫn phải bắn notify.
  bool _appForeground = false;
  int _lastFgHeartbeatMs = 0;
  String _chip = AppConfig.defaultChipId;
  String? _lastAlarmKey;
  int _lastAlarmMs = 0;
  String? _activeType;
  String? _activeTitle;
  String? _activeBody;
  double? _water;
  double? _soil;
  double? _roll;
  double? _pitch;
  bool _wetLatched = false;
  bool _tiltLatched = false;
  static const double _tiltDegThreshold = 25;
  static const int _dedupeMs = 25000; // cho phép báo lại sau ~25s (gateway re-pub)

  String get _alarmTopic => 'tele/${_chip}_alarm/status';
  String get _waterTopic => 'tele/${_chip}_water/status';
  String get _soilTopic => 'tele/${_chip}_soil/status';
  String get _rollTopic => 'tele/${_chip}_roll/status';
  String get _pitchTopic => 'tele/${_chip}_pitch/status';

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    // Isolate riêng — luôn init lại plugin thông báo
    await SatloNotifications.init(force: true);
    await _openMqtt(force: true);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Mất heartbeat từ UI > 12s → coi như app đã tắt/nền.
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_appForeground &&
        _lastFgHeartbeatMs > 0 &&
        now - _lastFgHeartbeatMs > 12000) {
      _appForeground = false;
    }
    unawaited(_onTick());
  }

  Future<void> _onTick() async {
    final c = _client;
    if (c == null ||
        c.connectionStatus?.state != MqttConnectionState.connected) {
      await _openMqtt(force: false);
      return;
    }
    // mqtt_client 10.x không còn ping() public — keepAlivePeriod tự gửi PINGREQ.
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
    final msg = data.toString().trim();
    if (msg == 'APP_FG' || msg == 'APP_FG_HEARTBEAT') {
      _appForeground = true;
      _lastFgHeartbeatMs = DateTime.now().millisecondsSinceEpoch;
      return;
    }
    if (msg == 'APP_BG') {
      _appForeground = false;
      _lastFgHeartbeatMs = 0;
      // Xóa chốt cũ — nếu alarm vẫn ON, báo lại ngay khi app vừa tắt
      _lastAlarmKey = null;
      _lastAlarmMs = 0;
      unawaited(_onAppWentBackground());
      return;
    }
    if (msg.isEmpty || msg == _chip) return;
    _chip = msg;
    unawaited(_openMqtt(force: true));
  }

  Future<void> _onAppWentBackground() async {
    await SatloNotifications.clearAlertGuards();
    await SatloNotifications.init(force: true);
    await FlutterForegroundTask.updateService(
      notificationTitle: 'SATLO đang giám sát',
      notificationText: 'App đã tắt — vẫn báo khi có alarm',
    );
    // Alarm đang active (gateway còn ON) → bắn ngay 1 lần khi vừa tắt app
    if (_activeType != null &&
        _activeTitle != null &&
        _activeBody != null) {
      await _fireAlert(
        type: _activeType!,
        title: _activeTitle!,
        body: _activeBody!,
        forceNotify: true,
      );
    }
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
      c.keepAlivePeriod = 20;
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
        notificationText: _appForeground
            ? 'Máy $_chip online'
            : 'Máy $_chip online — tắt app vẫn báo động',
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
        _lastAlarmMs = 0;
        _activeType = null;
        _activeTitle = null;
        _activeBody = null;
        _tiltLatched = false;
        _wetLatched = false;
        return;
      }
      final type = '${j['type'] ?? 'ALERT'}';
      final t = type.toUpperCase();
      if (t == 'TILT') _tiltLatched = true;
      if (t == 'WET_RISK') _wetLatched = true;
      final title = _titleFor(type);
      final body = _bodyFor(type, j);
      _activeType = type;
      _activeTitle = title;
      _activeBody = body;
      await _fireAlert(type: type, title: title, body: body);
    } catch (_) {
      await _fireAlert(
        type: 'ALERT',
        title: '⚠️ Cảnh báo SATLO',
        body: payload,
      );
    }
  }

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
    final title = '⚠️ Cảnh báo nguy cơ lũ!';
    final body =
        'Lượng mưa ${w.toStringAsFixed(0)}% · Đất ${s.toStringAsFixed(0)}% — kiểm tra ngay.';
    _activeType = 'WET_RISK';
    _activeTitle = title;
    _activeBody = body;
    await _fireAlert(type: 'WET_RISK', title: title, body: body);
  }

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
    final title = '⚠️ Cảnh báo nghiêng';
    final body =
        'Góc nghiêng R ${r.toStringAsFixed(0)}° · P ${p.toStringAsFixed(0)}° — kiểm tra ngay.';
    _activeType = 'TILT';
    _activeTitle = title;
    _activeBody = body;
    await _fireAlert(type: 'TILT', title: title, body: body);
  }

  Future<void> _fireAlert({
    required String type,
    required String title,
    required String body,
    bool forceNotify = false,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final key = '$type|$title|$body';
    if (!forceNotify &&
        key == _lastAlarmKey &&
        now - _lastAlarmMs < _dedupeMs) {
      return;
    }
    _lastAlarmKey = key;
    _lastAlarmMs = now;

    // Luôn bắn heads-up từ service nền — đây là đường chính khi tắt/vuốt app.
    // (UI mở vẫn có SatloProvider; channel dedupe 15s tránh spam trùng type.)
    await SatloNotifications.showFloodAlert(
      type: type,
      title: title,
      body: body,
      force: forceNotify || !_appForeground,
    );
    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: _appForeground
          ? body
          : '🚨 $title — tắt app vẫn báo',
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
