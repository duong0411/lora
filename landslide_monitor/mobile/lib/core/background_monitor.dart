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

import 'alert_store.dart';
import 'config.dart';
import 'notifications.dart';

/// MQTT trong Foreground Service — cảnh báo khi tắt app.
///
/// Quan trọng: heads-up chính đi qua [FlutterForegroundTask.updateService]
/// (notification native của FGS). Plugin local-notifications trong isolate
/// nền thường không hiện khi app đã bị vuốt.
class BackgroundMonitor {
  BackgroundMonitor._();

  static const _prefsChipKey = 'satlo_chip_id';
  static const _taskChipKey = 'chip_id';

  static bool get _mobile {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  static void configure() {
    // Thanh FGS chỉ giữ MQTT chạy nền (im lặng) — cảnh báo = banner Facebook riêng
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'satlo_fg_watch_v6',
        channelName: 'SATLO chạy nền',
        channelDescription:
            'Giữ kết nối MQTT. Cảnh báo hiện bằng thông báo riêng kiểu Facebook.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        enableVibration: false,
        playSound: false,
        showBadge: false,
        onlyAlertOnce: true,
        visibility: NotificationVisibility.VISIBILITY_PUBLIC,
        showWhen: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(3000),
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

  static void setAppForeground(bool foreground) {
    if (!_mobile) return;
    try {
      FlutterForegroundTask.sendDataToTask(
        foreground ? 'APP_FG' : 'APP_BG',
      );
    } catch (_) {}
  }

  static Future<void> _persistChip(String chip) async {
    final id = chip.trim().isEmpty ? AppConfig.defaultChipId : chip.trim();
    AppConfig.setChipId(id);
    try {
      await FlutterForegroundTask.saveData(key: _taskChipKey, value: id);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsChipKey, id);
    } catch (_) {}
  }

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
      await _persistChip(AppConfig.chipId);

      var notifPerm =
          await FlutterForegroundTask.checkNotificationPermission();
      if (notifPerm != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
        notifPerm =
            await FlutterForegroundTask.checkNotificationPermission();
      }

      if (Platform.isAndroid) {
        if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
          await FlutterForegroundTask.requestIgnoreBatteryOptimization();
        }
      }

      final running = await FlutterForegroundTask.isRunningService;
      if (running) {
        FlutterForegroundTask.sendDataToTask(AppConfig.chipId);
        await FlutterForegroundTask.updateService(
          notificationTitle: 'SATLO đang chạy nền',
          notificationText:
              'Chip ${AppConfig.chipId} — MQTT OK. Cảnh báo hiện banner riêng.',
        );
        if (showTestAlert) {
          await SatloNotifications.showFloodAlert(
            type: 'TEST',
            title: '✅ Thử thông báo SATLO',
            body:
                'Banner kiểu Facebook. Vuốt Home — vẫn hiện khi có alarm (giữ thanh chạy nền).',
            force: true,
          );
        }
        return notifPerm == NotificationPermission.granted;
      }

      final result = await FlutterForegroundTask.startService(
        serviceId: 791,
        serviceTypes: const [ForegroundServiceTypes.remoteMessaging],
        notificationTitle: 'SATLO đang chạy nền',
        notificationText:
            'Chip ${AppConfig.chipId} — giữ thanh này để nhận thông báo khi tắt app',
        callback: satloBackgroundCallback,
      );

      final ok = result is! ServiceRequestFailure;
      if (!ok) {
        if (kDebugMode) debugPrint('BackgroundMonitor start FAIL: $result');
        return false;
      }

      FlutterForegroundTask.sendDataToTask(AppConfig.chipId);
      await Future<void>.delayed(const Duration(milliseconds: 800));

      if (showTestAlert) {
        await SatloNotifications.showFloodAlert(
          type: 'TEST',
          title: '✅ Thử thông báo SATLO',
          body:
              'Banner kiểu Facebook. Vuốt Home — vẫn hiện khi có alarm (giữ thanh chạy nền).',
          force: true,
        );
      }
      return true;
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
  bool _appForeground = false;
  int _lastFgHeartbeatMs = 0;
  String _chip = AppConfig.defaultChipId;
  String? _lastAlarmKey;
  int _lastAlarmMs = 0;
  double? _water;
  double? _soil;
  double? _roll;
  double? _pitch;
  bool _wetLatched = false;
  bool _tiltLatched = false;
  static const double _tiltDegThreshold = 25;
  static const int _realertMs = 25000;
  static const int _dedupeMs = 6000;

  String get _alarmTopic => 'tele/${_chip}_alarm/status';
  String get _waterTopic => 'tele/${_chip}_water/status';
  String get _soilTopic => 'tele/${_chip}_soil/status';
  String get _rollTopic => 'tele/${_chip}_roll/status';
  String get _pitchTopic => 'tele/${_chip}_pitch/status';

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _loadChip();
    try {
      await SatloNotifications.init(force: true);
    } catch (_) {}
    await _openMqtt(force: true);
    await _realertFromStore(force: true);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_appForeground &&
        _lastFgHeartbeatMs > 0 &&
        now - _lastFgHeartbeatMs > 6000) {
      _appForeground = false;
    }
    unawaited(_onTick());
  }

  Future<void> _onTick() async {
    final c = _client;
    final st = c?.connectionStatus?.state;
    if (c == null || st != MqttConnectionState.connected) {
      await _openMqtt(force: true);
    }
    // Luôn realert khi app không mở — kể cả vừa vuốt Home
    if (!_appForeground) {
      await _realertFromStore(force: false);
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
    final msg = data.toString().trim();
    if (msg == 'APP_FG' || msg == 'APP_FG_HEARTBEAT') {
      _appForeground = true;
      _lastFgHeartbeatMs = DateTime.now().millisecondsSinceEpoch;
      return;
    }
    if (msg == 'APP_BG') {
      _appForeground = false;
      _lastFgHeartbeatMs = 0;
      unawaited(_onAppWentBackground());
      return;
    }
    if (msg.isEmpty) return;
    if (msg != _chip) {
      _chip = msg;
      unawaited(
        FlutterForegroundTask.saveData(key: 'chip_id', value: _chip),
      );
      unawaited(_openMqtt(force: true));
    }
  }

  Future<void> _loadChip() async {
    try {
      final fromTask =
          await FlutterForegroundTask.getData<String>(key: 'chip_id');
      if (fromTask != null && fromTask.trim().isNotEmpty) {
        _chip = fromTask.trim();
        AppConfig.setChipId(_chip);
        return;
      }
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final saved = prefs.getString('satlo_chip_id');
      if (saved != null && saved.trim().isNotEmpty) {
        _chip = saved.trim();
        AppConfig.setChipId(_chip);
      }
    } catch (_) {}
  }

  Future<void> _onAppWentBackground() async {
    await FlutterForegroundTask.updateService(
      notificationTitle: 'SATLO đang giám sát',
      notificationText: 'App đã tắt — đang nghe MQTT $_chip',
    );
    await _realertFromStore(force: true);
  }

  Future<void> _realertFromStore({required bool force}) async {
    final a = await AlertStore.read();
    if (a == null) return;
    if (!force) {
      final last = await AlertStore.lastNotifyMs();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last < _realertMs) return;
    }
    await _fireAlert(
      type: a.type,
      title: a.title,
      body: a.body,
      forceNotify: true,
      persist: false,
    );
  }

  Future<void> _openMqtt({required bool force}) async {
    if (_busy) return;
    final connected =
        _client?.connectionStatus?.state == MqttConnectionState.connected;
    if (!force && connected) return;
    _busy = true;
    try {
      await _loadChip();

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
      c.keepAlivePeriod = 12;
      c.autoReconnect = true;
      c.resubscribeOnAutoReconnect = true;
      c.onConnected = () => _subscribeAll(c);
      c.onAutoReconnect = () {};
      c.onAutoReconnected = () => _subscribeAll(c);
      c.connectionMessage =
          MqttConnectMessage().withClientIdentifier(cid).startClean();

      await c.connect().timeout(const Duration(seconds: 20));
      if (c.connectionStatus?.state != MqttConnectionState.connected) {
        await FlutterForegroundTask.updateService(
          notificationTitle: 'SATLO — mất MQTT',
          notificationText: 'Đang thử lại chip $_chip',
        );
        return;
      }

      _subscribeAll(c);
      _sub = c.updates?.listen(_onMqttEvents);
      _client = c;

      await FlutterForegroundTask.updateService(
        notificationTitle: 'SATLO đang giám sát',
        notificationText: 'MQTT OK · $_chip · tắt app vẫn báo',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('SatloBackgroundHandler MQTT: $e');
      await FlutterForegroundTask.updateService(
        notificationTitle: 'SATLO — mất MQTT',
        notificationText: 'Đang thử lại...',
      );
    } finally {
      _busy = false;
    }
  }

  void _subscribeAll(MqttServerClient c) {
    c.subscribe(_alarmTopic, MqttQos.atLeastOnce);
    c.subscribe(_waterTopic, MqttQos.atMostOnce);
    c.subscribe(_soilTopic, MqttQos.atMostOnce);
    c.subscribe(_rollTopic, MqttQos.atMostOnce);
    c.subscribe(_pitchTopic, MqttQos.atMostOnce);
  }

  void _onMqttEvents(List<MqttReceivedMessage<MqttMessage>> events) {
    for (final e in events) {
      final rec = e.payload as MqttPublishMessage;
      final payload =
          MqttPublishPayload.bytesToStringAsString(rec.payload.message);
      unawaited(_onMessage(e.topic, payload));
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
        _tiltLatched = false;
        _wetLatched = false;
        await AlertStore.clear();
        await FlutterForegroundTask.updateService(
          notificationTitle: 'SATLO đang giám sát',
          notificationText: 'MQTT OK · $_chip · tắt app vẫn báo',
        );
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
        forceNotify: true,
      );
    } catch (_) {
      await _fireAlert(
        type: 'ALERT',
        title: '⚠️ Cảnh báo SATLO',
        body: payload,
        forceNotify: true,
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
    await _fireAlert(
      type: 'WET_RISK',
      title: '⚠️ Cảnh báo nguy cơ lũ!',
      body:
          'Lượng mưa ${w.toStringAsFixed(0)}% · Đất ${s.toStringAsFixed(0)}% — kiểm tra ngay.',
      forceNotify: true,
    );
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
    await _fireAlert(
      type: 'TILT',
      title: '⚠️ Cảnh báo nghiêng',
      body:
          'Góc nghiêng R ${r.toStringAsFixed(0)}° · P ${p.toStringAsFixed(0)}° — kiểm tra ngay.',
      forceNotify: true,
    );
  }

  Future<void> _fireAlert({
    required String type,
    required String title,
    required String body,
    bool forceNotify = false,
    bool persist = true,
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

    if (persist) {
      await AlertStore.setActive(type: type, title: title, body: body);
    }
    // Banner Facebook riêng (native Kotlin) — không đụng thanh FGS im lặng
    try {
      await SatloNotifications.showFloodAlert(
        type: type,
        title: title,
        body: body,
        force: true,
      );
    } catch (_) {}

    // Thanh FGS chỉ báo đang nghe — không thay bằng nội dung alarm
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'SATLO đang chạy nền',
        notificationText: 'Đã gửi cảnh báo · $_chip',
      );
    } catch (_) {}
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
    final metrics = (w != null || s != null)
        ? ' · Mưa ${w ?? '--'}% · Đất ${s ?? '--'}%'
        : '';
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
