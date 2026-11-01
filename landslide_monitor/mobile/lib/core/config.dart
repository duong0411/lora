class AppConfig {
  static const String apiBaseUrl = 'https://duynguyen.io.vn/api';
  static const String brokerUrl = 'wss://mqtt.duynguyen.io.vn/mqtt';
  static const int brokerPort = 443;
  static const String defaultChipId = 'SATLO_GW01';
  static const String brand = 'SẠT LỞ';
  static const String productLine = 'Giám sát sạt lở IoT realtime';

  static String chipId = defaultChipId;

  static void setChipId(String id) {
    final cleaned = id.trim();
    chipId = cleaned.isEmpty ? defaultChipId : cleaned;
  }

  static String get topicOnline => 'tele/$chipId/status';
  static String get topicWater => 'tele/${chipId}_water/status';
  static String get topicSoil => 'tele/${chipId}_soil/status';
  static String get topicRoll => 'tele/${chipId}_roll/status';
  static String get topicPitch => 'tele/${chipId}_pitch/status';
  static String get topicAx => 'tele/${chipId}_ax/status';
  static String get topicAy => 'tele/${chipId}_ay/status';
  static String get topicAz => 'tele/${chipId}_az/status';
  static String get topicLora => 'tele/${chipId}_lora/status';
  static String get topicAlarm => 'tele/${chipId}_alarm/status';

  static List<String> get subscribeTopics => [
        topicOnline,
        topicWater,
        topicSoil,
        topicRoll,
        topicPitch,
        topicAx,
        topicAy,
        topicAz,
        topicLora,
        topicAlarm,
      ];
}
