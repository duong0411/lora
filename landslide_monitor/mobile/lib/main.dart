import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Đồng bộ MQTT với iot_class (lớp học thông minh):
/// Host WSS: wss://mqtt.duynguyen.io.vn/mqtt  port 443
/// Topic: tele/{device}/status

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.instance.init();
  runApp(const LandslideApp());
}

class LandslideApp extends StatelessWidget {
  const LandslideApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cảnh báo Sạt lở',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFEE4D2D),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();
  final _plugin = FlutterLocalNotificationsPlugin();
  int _id = 2000;

  Future<void> init() async {
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

  Future<void> show({required String title, required String body}) async {
    const android = AndroidNotificationDetails(
      'satlo_alerts',
      'Cảnh báo sạt lở',
      channelDescription: 'Thông báo khi gateway/còi cảnh báo',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.alarm,
      playSound: true,
      enableVibration: true,
      color: Color(0xFFEE4D2D),
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

class Telemetry {
  double water;
  double soil;
  double roll;
  double pitch;
  String lora;
  String alarm;
  DateTime at;

  Telemetry({
    this.water = 0,
    this.soil = 0,
    this.roll = 0,
    this.pitch = 0,
    this.lora = '--',
    this.alarm = 'OFF',
    DateTime? at,
  }) : at = at ?? DateTime.now();
}

class AlertItem {
  final String type;
  final String title;
  final String body;
  final DateTime at;
  AlertItem(this.type, this.title, this.body, this.at);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Giống iot_class/lib/core/services/mqtt_service.dart
  static const defaultWss = 'wss://mqtt.duynguyen.io.vn/mqtt';
  static const defaultPort = 443;

  final hostCtrl = TextEditingController(text: defaultWss);
  final portCtrl = TextEditingController(text: '$defaultPort');
  final chipCtrl = TextEditingController(text: 'SATLO_GW01');

  MqttServerClient? client;
  bool mqttConnected = false;
  bool connecting = false;
  String statusText = 'Chưa kết nối MQTT WSS';
  final telemetry = Telemetry();
  final alerts = <AlertItem>[];
  String? lastAlarmKey;

  String get chip =>
      chipCtrl.text.trim().isEmpty ? 'SATLO_GW01' : chipCtrl.text.trim();

  @override
  void initState() {
    super.initState();
    _load().then((_) => connectMqtt());
  }

  @override
  void dispose() {
    client?.disconnect();
    hostCtrl.dispose();
    portCtrl.dispose();
    chipCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    hostCtrl.text = p.getString('wss') ?? defaultWss;
    portCtrl.text = p.getString('port') ?? '$defaultPort';
    chipCtrl.text = p.getString('chip') ?? 'SATLO_GW01';
    setState(() {});
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('wss', hostCtrl.text.trim());
    await p.setString('port', portCtrl.text.trim());
    await p.setString('chip', chipCtrl.text.trim());
  }

  Future<void> connectMqtt() async {
    if (connecting) return;
    setState(() {
      connecting = true;
      statusText = 'Đang kết nối WSS...';
    });
    await _save();

    try {
      client?.disconnect();
    } catch (_) {}

    final wss = hostCtrl.text.trim();
    final port = int.tryParse(portCtrl.text.trim()) ?? 443;
    final cid = 'satlo-app-${DateTime.now().millisecondsSinceEpoch}';

    // Giống đúng iot_class
    final c = MqttServerClient.withPort(wss, cid, port);
    c.useWebSocket = true;
    c.secure = false;
    c.websocketProtocols = MqttClientConstants.protocolsSingleDefault;
    c.logging(on: false);
    c.keepAlivePeriod = 30;
    c.autoReconnect = true;
    c.resubscribeOnAutoReconnect = true;
    c.onDisconnected = () {
      if (!mounted) return;
      setState(() {
        mqttConnected = false;
        statusText = 'MQTT mất kết nối — auto reconnect...';
      });
    };
    c.onConnected = () {
      if (!mounted) return;
      setState(() {
        mqttConnected = true;
        statusText = 'MQTT WSS OK';
      });
      _subscribeAll(c);
    };
    c.connectionMessage =
        MqttConnectMessage().withClientIdentifier(cid).startClean();

    try {
      await c.connect().timeout(const Duration(seconds: 12));
    } catch (e) {
      setState(() {
        connecting = false;
        mqttConnected = false;
        statusText = 'Kết nối thất bại: $e';
      });
      return;
    }

    if (c.connectionStatus?.state != MqttConnectionState.connected) {
      setState(() {
        connecting = false;
        mqttConnected = false;
        statusText = 'Không kết nối được broker';
      });
      return;
    }

    client = c;
    _subscribeAll(c);
    c.updates?.listen((events) {
      for (final e in events) {
        final rec = e.payload as MqttPublishMessage;
        final payload =
            MqttPublishPayload.bytesToStringAsString(rec.payload.message);
        _onMessage(e.topic, payload);
      }
    });

    setState(() {
      connecting = false;
      mqttConnected = true;
      statusText = 'Đã subscribe $chip';
    });
  }

  void _subscribeAll(MqttServerClient c) {
    final topics = [
      'tele/$chip/status',
      'tele/${chip}_water/status',
      'tele/${chip}_soil/status',
      'tele/${chip}_roll/status',
      'tele/${chip}_pitch/status',
      'tele/${chip}_lora/status',
      'tele/${chip}_alarm/status',
    ];
    for (final t in topics) {
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

    if (topic.endsWith('_water/status')) {
      setState(() => telemetry.water = (v as num?)?.toDouble() ?? telemetry.water);
      return;
    }
    if (topic.endsWith('_soil/status')) {
      setState(() => telemetry.soil = (v as num?)?.toDouble() ?? telemetry.soil);
      return;
    }
    if (topic.endsWith('_roll/status')) {
      setState(() => telemetry.roll = (v as num?)?.toDouble() ?? telemetry.roll);
      return;
    }
    if (topic.endsWith('_pitch/status')) {
      setState(() => telemetry.pitch = (v as num?)?.toDouble() ?? telemetry.pitch);
      return;
    }
    if (topic.endsWith('_lora/status')) {
      setState(() => telemetry.lora = '$v');
      return;
    }

    if (topic.endsWith('_alarm/status')) {
      try {
        final j = jsonDecode(payload) as Map<String, dynamic>;
        final value = '${j['value'] ?? ''}'.toUpperCase();
        final type = '${j['type'] ?? 'ALERT'}';
        final title = '${j['title'] ?? 'Cảnh báo sạt lở'}';
        final body = '${j['body'] ?? payload}';
        setState(() => telemetry.alarm = value);

        if (value == 'ON') {
          final key = '$type|$title|$body';
          if (key != lastAlarmKey) {
            lastAlarmKey = key;
            setState(() {
              alerts.insert(0, AlertItem(type, title, body, DateTime.now()));
              if (alerts.length > 40) alerts.removeLast();
            });
            NotificationService.instance.show(title: title, body: body);
          }
        } else {
          lastAlarmKey = null;
        }
      } catch (_) {
        NotificationService.instance
            .show(title: 'Cảnh báo sạt lở', body: payload);
      }
    }
  }

  Color get _badgeColor {
    if (telemetry.alarm == 'ON') return const Color(0xFFD32F2F);
    if (telemetry.lora == 'ONLINE') return const Color(0xFF2E7D32);
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEE4D2D),
        foregroundColor: Colors.white,
        title: const Text('Cảnh báo Sạt lở'),
        actions: [
          IconButton(
            onPressed: connecting ? null : connectMqtt,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: ListTile(
              leading: Icon(
                mqttConnected ? Icons.cloud_done : Icons.cloud_off,
                color: mqttConnected ? Colors.green : Colors.red,
              ),
              title: Text(mqttConnected ? 'MQTT WSS Online' : 'MQTT Offline'),
              subtitle: Text(statusText),
              trailing: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _badgeColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  telemetry.alarm == 'ON' ? 'CẢNH BÁO' : telemetry.lora,
                  style: TextStyle(
                      color: _badgeColor, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Cấu hình MQTT (chuẩn iot_class)',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: hostCtrl,
                    decoration: const InputDecoration(
                      labelText: 'WSS URL',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: portCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Port',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: chipCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Chip ID',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFEE4D2D)),
                    onPressed: connecting ? null : connectMqtt,
                    child:
                        Text(connecting ? 'Đang kết nối...' : 'Lưu & Kết nối'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Thông số realtime',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  _kv('LoRa', telemetry.lora),
                  _kv('Lượng mưa / mực nước',
                      '${telemetry.water.toStringAsFixed(1)} %'),
                  _kv('Độ ẩm đất', '${telemetry.soil.toStringAsFixed(1)} %'),
                  _kv('IMU Roll', '${telemetry.roll.toStringAsFixed(1)} °'),
                  _kv('IMU Pitch', '${telemetry.pitch.toStringAsFixed(1)} °'),
                  _kv('Alarm', telemetry.alarm),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Lịch sử cảnh báo',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  if (alerts.isEmpty)
                    const Text('Chưa có cảnh báo')
                  else
                    ...alerts.take(20).map(
                          (a) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.notifications_active,
                                color: Color(0xFFEE4D2D)),
                            title: Text(a.title),
                            subtitle: Text('${a.type}\n${a.body}'),
                            isThreeLine: true,
                            dense: true,
                          ),
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(k)),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
