import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import 'alert_store.dart';
import 'config.dart';
import 'notifications.dart';

class AlertItem {
  final String type;
  final String title;
  final String body;
  final DateTime at;
  AlertItem(this.type, this.title, this.body, this.at);
}

class SatloProvider extends ChangeNotifier {
  MqttServerClient? _client;
  bool mqttConnected = false;
  bool connecting = false;
  String statusText = 'Chưa kết nối MQTT';
  String? lastAlarmKey;

  double? water;
  double? soil;
  double? roll;
  double? pitch;
  double? ax;
  double? ay;
  double? az;
  String lora = '--';
  String gatewayOnline = '--';
  String alarm = 'OFF';
  final alerts = <AlertItem>[];
  bool _tiltLatched = false;
  bool _wetLatched = false;

  /// Ngưỡng dự phòng khi gateway chưa kịp (hoặc miss) topic alarm.
  static const double tiltDegThreshold = 25;

  bool get hasTelemetry =>
      water != null || soil != null || ax != null || roll != null;

  bool get isAlarm => alarm.toUpperCase() == 'ON';

  Future<bool> connectWithChip(String chipId) async {
    AppConfig.setChipId(chipId);
    connecting = true;
    statusText = 'Đang kết nối MQTT...';
    notifyListeners();

    try {
      _client?.disconnect();
    } catch (_) {}

    final cid = 'satlo-app-${DateTime.now().millisecondsSinceEpoch}';
    final c = MqttServerClient.withPort(AppConfig.brokerUrl, cid, AppConfig.brokerPort);
    c.useWebSocket = true;
    c.secure = false;
    c.websocketProtocols = MqttClientConstants.protocolsSingleDefault;
    c.logging(on: false);
    c.keepAlivePeriod = 30;
    c.autoReconnect = true;
    c.resubscribeOnAutoReconnect = true;
    c.onDisconnected = () {
      mqttConnected = false;
      statusText = 'MQTT mất kết nối — đang thử lại...';
      notifyListeners();
    };
    c.onConnected = () {
      mqttConnected = true;
      statusText = 'MQTT online · chip ${AppConfig.chipId}';
      _subscribe(c);
      notifyListeners();
    };
    c.connectionMessage =
        MqttConnectMessage().withClientIdentifier(cid).startClean();

    try {
      await c.connect().timeout(const Duration(seconds: 12));
    } catch (e) {
      connecting = false;
      mqttConnected = false;
      statusText = 'Kết nối thất bại';
      notifyListeners();
      return false;
    }

    if (c.connectionStatus?.state != MqttConnectionState.connected) {
      connecting = false;
      mqttConnected = false;
      statusText = 'Không kết nối được broker';
      notifyListeners();
      return false;
    }

    _client = c;
    _subscribe(c);
    c.updates?.listen((events) {
      for (final e in events) {
        final rec = e.payload as MqttPublishMessage;
        final payload =
            MqttPublishPayload.bytesToStringAsString(rec.payload.message);
        _onMessage(e.topic, payload);
      }
    });

    connecting = false;
    mqttConnected = true;
    statusText = 'Đã subscribe ${AppConfig.chipId}';
    notifyListeners();
    return true;
  }

  Future<void> reconnect() async {
    await connectWithChip(AppConfig.chipId);
  }

  void disconnectChip() {
    try {
      _client?.disconnect();
    } catch (_) {}
    _client = null;
    mqttConnected = false;
    connecting = false;
    water = soil = roll = pitch = ax = ay = az = null;
    lora = '--';
    gatewayOnline = '--';
    alarm = 'OFF';
    statusText = 'Đã ngắt kết nối';
    notifyListeners();
  }

  void _subscribe(MqttServerClient c) {
    for (final t in AppConfig.subscribeTopics) {
      c.subscribe(t, MqttQos.atMostOnce);
    }
  }

  ({String title, String body}) _alertCopy(
    String type,
    Map<String, dynamic> j,
  ) {
    final rawTitle = '${j['title'] ?? ''}'.trim();
    final rawBody = '${j['body'] ?? ''}'.trim();
    final w = j['water'];
    final s = j['soil'];
    final metrics = (w != null || s != null)
        ? ' · Mưa ${w ?? '--'}% · Đất ${s ?? '--'}%'
        : '';

    // Luôn dùng tiếng Việt có dấu trên app (gateway gửi ASCII).
    switch (type.toUpperCase()) {
      case 'WET_RISK':
        return (
          title: '⚠️ Cảnh báo nguy cơ lũ!',
          body:
              'Lượng mưa và độ ẩm đất cao — nguy cơ ngập/lũ.$metrics',
        );
      case 'SAT_LO':
        return (
          title: '🚨 Cảnh báo sạt lở!',
          body:
              'Rung/nghiêng + ẩm/nước cao — kiểm tra ngay.$metrics',
        );
      case 'IMPACT':
        return (
          title: '⚠️ Cảnh báo rung lắc',
          body: 'IMU phát hiện va đập / rung mạnh.',
        );
      case 'TILT':
        return (
          title: '⚠️ Cảnh báo nghiêng',
          body: 'Góc nghiêng vượt ngưỡng an toàn.',
        );
      default:
        return (
          title: rawTitle.isEmpty ? '⚠️ Cảnh báo SATLO' : rawTitle,
          body: rawBody.isEmpty ? 'Gateway đang báo động.' : rawBody,
        );
    }
  }

  dynamic _valueOf(String payload) {
    final p = payload.trim();
    if (p == 'online' || p == 'offline') return p;
    try {
      final j = jsonDecode(p);
      if (j is Map && j.containsKey('value')) return j['value'];
      return j;
    } catch (_) {
      return p;
    }
  }

  void _onMessage(String topic, String payload) {
    final v = _valueOf(payload);

    if (topic == AppConfig.topicOnline) {
      gatewayOnline = '$v'.toUpperCase();
    } else if (topic == AppConfig.topicWater) {
      water = (v as num?)?.toDouble();
      _maybeWetFromTelemetry();
    } else if (topic == AppConfig.topicSoil) {
      soil = (v as num?)?.toDouble();
      _maybeWetFromTelemetry();
    } else if (topic == AppConfig.topicRoll) {
      roll = (v as num?)?.toDouble();
      _maybeTiltFromTelemetry();
    } else if (topic == AppConfig.topicPitch) {
      pitch = (v as num?)?.toDouble();
      _maybeTiltFromTelemetry();
    } else if (topic == AppConfig.topicAx) {
      ax = (v as num?)?.toDouble();
    } else if (topic == AppConfig.topicAy) {
      ay = (v as num?)?.toDouble();
    } else if (topic == AppConfig.topicAz) {
      az = (v as num?)?.toDouble();
    } else if (topic == AppConfig.topicLora) {
      lora = '$v'.toUpperCase();
    } else if (topic == AppConfig.topicAlarm) {
      try {
        final j = jsonDecode(payload) as Map<String, dynamic>;
        final value = '${j['value'] ?? ''}'.toUpperCase();
        alarm = value;
        if (value == 'ON') {
          final type = '${j['type'] ?? 'ALERT'}'.toUpperCase();
          if (type == 'TILT') _tiltLatched = true;
          if (type == 'WET_RISK') _wetLatched = true;
          final mapped = _alertCopy(type, j);
          _pushAlert(type, mapped.title, mapped.body);
        } else {
          lastAlarmKey = null;
          _tiltLatched = false;
          _wetLatched = false;
          unawaited(AlertStore.clear());
        }
      } catch (_) {
        alarm = 'ON';
        unawaited(
          SatloNotifications.showFloodAlert(
            type: 'ALERT',
            title: '⚠️ Cảnh báo SATLO',
            body: payload,
          ),
        );
      }
    }
    notifyListeners();
  }

  void _pushAlert(String type, String title, String body) {
    final key = '$type|$title|$body';
    if (key == lastAlarmKey) return;
    lastAlarmKey = key;
    alarm = 'ON';
    alerts.insert(0, AlertItem(type, title, body, DateTime.now()));
    if (alerts.length > 40) alerts.removeLast();
    // Lưu cho isolate nền — tắt app vẫn biết alarm đang ON để bắn lại
    unawaited(AlertStore.setActive(type: type, title: title, body: body));
    unawaited(
      SatloNotifications.showFloodAlert(
        type: type,
        title: title,
        body: body,
        force: true,
      ),
    );
  }

  /// OLED đã NGHIENG nhưng miss MQTT alarm → vẫn báo từ roll/pitch.
  void _maybeTiltFromTelemetry() {
    final r = (roll ?? 0).abs();
    final p = (pitch ?? 0).abs();
    final hot = r >= tiltDegThreshold || p >= tiltDegThreshold;
    if (!hot) {
      _tiltLatched = false;
      return;
    }
    if (_tiltLatched) return;
    _tiltLatched = true;
    _pushAlert(
      'TILT',
      '⚠️ Cảnh báo nghiêng',
      'Góc nghiêng R ${r.toStringAsFixed(0)}° · P ${p.toStringAsFixed(0)}° — kiểm tra ngay.',
    );
  }

  void _maybeWetFromTelemetry() {
    final w = water ?? 0;
    final s = soil ?? 0;
    final hot = w >= 35 || s >= 70;
    if (!hot) {
      _wetLatched = false;
      return;
    }
    if (_wetLatched) return;
    _wetLatched = true;
    _pushAlert(
      'WET_RISK',
      '⚠️ Cảnh báo nguy cơ lũ!',
      'Lượng mưa ${w.toStringAsFixed(0)}% · Đất ${s.toStringAsFixed(0)}% — kiểm tra ngay.',
    );
  }
}
