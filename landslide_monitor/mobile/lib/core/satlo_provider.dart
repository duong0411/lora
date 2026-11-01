import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

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
    } else if (topic == AppConfig.topicSoil) {
      soil = (v as num?)?.toDouble();
    } else if (topic == AppConfig.topicRoll) {
      roll = (v as num?)?.toDouble();
    } else if (topic == AppConfig.topicPitch) {
      pitch = (v as num?)?.toDouble();
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
          final type = '${j['type'] ?? 'ALERT'}';
          final title = '${j['title'] ?? 'Cảnh báo sạt lở'}';
          final body = '${j['body'] ?? payload}';
          final key = '$type|$title|$body';
          if (key != lastAlarmKey) {
            lastAlarmKey = key;
            alerts.insert(0, AlertItem(type, title, body, DateTime.now()));
            if (alerts.length > 40) alerts.removeLast();
            unawaited(SatloNotifications.show(title: title, body: body));
          }
        } else {
          lastAlarmKey = null;
        }
      } catch (_) {
        alarm = 'ON';
        unawaited(
          SatloNotifications.show(title: 'Cảnh báo sạt lở', body: payload),
        );
      }
    }
    notifyListeners();
  }
}
