/**
 * Landslide Monitor - GATEWAY (ESP32)
 *
 * Tách lớp rõ:
 *  - LoRa + OLED + Còi: chạy LOCAL, KHÔNG phụ thuộc WiFi/MQTT
 *  - WiFi/MQTT: chỉ đẩy dữ liệu/cảnh báo lên điện thoại
 *  - Mất mạng: LoRa vẫn nhận, còi vẫn kêu, OLED hiện trạng thái LoRa + MQTT
 *
 * MQTT (chuẩn iot_class):
 *   Host mqtt.duynguyen.io.vn:443/mqtt (WSS)
 *   Topic tele/{device}/status
 *
 * Giữ BOOT 3 giây -> portal cấu hình WiFi (không cần nạp lại firmware).
 */

#include <Arduino.h>
#include <WiFi.h>
#include <WiFiManager.h>
#include <WebSocketsClient.h>
#include <MQTTPubSubClient.h>
#include <Preferences.h>
#include <SPI.h>
#include <Wire.h>
#include <LoRa.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

// -------------------- PIN --------------------
#define LORA_NSS   5
#define LORA_RST   4
#define LORA_DIO0  25
#define LORA_SCK   18
#define LORA_MISO  19
#define LORA_MOSI  23
#define PIN_BUZZER 13
#define PIN_BOOT   0
#define I2C_SDA    21
#define I2C_SCL    22

#define SCREEN_W   128
#define SCREEN_H   64
#define OLED_ADDR  0x3C

#define LORA_FREQ      433E6
#define LORA_SPI_HZ    1000000UL
#define REG_VERSION    0x42
#define LORA_SYNCWORD  0x12

#define BUZZ_CH        0
#define BUZZ_FREQ      2700

#define UI_MS          200
#define MQTT_RETRY_MS  5000
#define WIFI_RETRY_MS  10000
#define TELEMETRY_MS   800    // đẩy phone nhanh; LoRa RX không chờ MQTT
#define HEART_MS       10000
#define LORA_STALE_MS  6000   // node ~1s/gói → WAIT nếu mất ~6s

// Giống iot_class SmartHome
#define MQTT_HOST_DEFAULT  "mqtt.duynguyen.io.vn"
#define MQTT_PORT_DEFAULT  "443"
#define MQTT_PATH          "/mqtt"
#define CHIP_DEFAULT       "SATLO_GW01"

char cfgChipId[32]   = CHIP_DEFAULT;
char cfgMqttHost[64] = MQTT_HOST_DEFAULT;
char cfgMqttPort[8]  = MQTT_PORT_DEFAULT;

Preferences prefs;
WebSocketsClient wsClient;
MQTTPubSubClient mqttClient;
SPIClass spiLoRa(HSPI);
Adafruit_SSD1306 display(SCREEN_W, SCREEN_H, &Wire, -1);
WiFiManager wm;

bool mqttInited = false;
bool oledOk = false;
bool loraOk = false;
bool wifiOk = false;
bool mqttOk = false;

struct NodeData {
  bool valid = false;
  uint32_t nodeId = 0;
  uint32_t seq = 0;
  float water = 0;
  float soil = 0;
  int rainFlag = 0;
  int soilDry = 0;
  float roll = 0;
  float pitch = 0;
  float ax = 0, ay = 0, az = 0;
  int impact = 0;
  int tilt = 0;
  int landslide = 0;
  int wetRisk = 0;
  int rssi = 0;
  float snr = 0;
  uint32_t lastRxMs = 0;
};

NodeData node;
uint32_t rxCount = 0;
uint32_t lastUiMs = 0;
uint32_t lastMqttTryMs = 0;
uint32_t lastWifiTryMs = 0;
uint32_t lastTelemetryMs = 0;
uint32_t lastHeartMs = 0;
uint32_t buzzUntilMs = 0;
uint32_t lastBuzzMs = 0;
uint32_t bootHoldStart = 0;
bool bootHolding = false;
bool telemetryPending = false;  // có gói LoRa mới → xếp hàng MQTT (không block RX)

int lastAlertLandslide = 0;
int lastAlertWet = 0;
int lastAlertImpact = 0;
int lastAlertTilt = 0;

// device suffixes (tele/{CHIP}_{suffix}/status)
char DEV_WATER[48];
char DEV_SOIL[48];
char DEV_ROLL[48];
char DEV_PITCH[48];
char DEV_AX[48];
char DEV_AY[48];
char DEV_AZ[48];
char DEV_ALARM[48];
char DEV_LORA[48];

void rebuildDevNames() {
  snprintf(DEV_WATER, sizeof(DEV_WATER), "%s_water", cfgChipId);
  snprintf(DEV_SOIL, sizeof(DEV_SOIL), "%s_soil", cfgChipId);
  snprintf(DEV_ROLL, sizeof(DEV_ROLL), "%s_roll", cfgChipId);
  snprintf(DEV_PITCH, sizeof(DEV_PITCH), "%s_pitch", cfgChipId);
  snprintf(DEV_AX, sizeof(DEV_AX), "%s_ax", cfgChipId);
  snprintf(DEV_AY, sizeof(DEV_AY), "%s_ay", cfgChipId);
  snprintf(DEV_AZ, sizeof(DEV_AZ), "%s_az", cfgChipId);
  snprintf(DEV_ALARM, sizeof(DEV_ALARM), "%s_alarm", cfgChipId);
  snprintf(DEV_LORA, sizeof(DEV_LORA), "%s_lora", cfgChipId);
}

// -------------------- BUZZER --------------------
void buzzOff() {
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWriteTone(PIN_BUZZER, 0);
  ledcWrite(PIN_BUZZER, 0);
#else
  ledcWriteTone(BUZZ_CH, 0);
  ledcWrite(BUZZ_CH, 0);
#endif
  buzzUntilMs = 0;
}

void buzzOn(uint32_t ms) {
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWriteTone(PIN_BUZZER, BUZZ_FREQ);
#else
  ledcWriteTone(BUZZ_CH, BUZZ_FREQ);
  ledcWrite(BUZZ_CH, 180);
#endif
  buzzUntilMs = millis() + ms;
}

void buzzerInit() {
  pinMode(PIN_BUZZER, OUTPUT);
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcAttach(PIN_BUZZER, BUZZ_FREQ, 8);
  ledcWrite(PIN_BUZZER, 0);
#else
  ledcSetup(BUZZ_CH, BUZZ_FREQ, 8);
  ledcAttachPin(PIN_BUZZER, BUZZ_CH);
  ledcWrite(BUZZ_CH, 0);
#endif
}

// -------------------- CFG --------------------
void loadCfg() {
  prefs.begin("satlo", true);
  String id = prefs.getString("chip", CHIP_DEFAULT);
  String host = prefs.getString("mhost", MQTT_HOST_DEFAULT);
  String port = prefs.getString("mport", MQTT_PORT_DEFAULT);
  prefs.end();
  strncpy(cfgChipId, id.c_str(), sizeof(cfgChipId) - 1);
  strncpy(cfgMqttHost, host.c_str(), sizeof(cfgMqttHost) - 1);
  strncpy(cfgMqttPort, port.c_str(), sizeof(cfgMqttPort) - 1);
  rebuildDevNames();
}

void saveCfg() {
  prefs.begin("satlo", false);
  prefs.putString("chip", cfgChipId);
  prefs.putString("mhost", cfgMqttHost);
  prefs.putString("mport", cfgMqttPort);
  prefs.end();
  rebuildDevNames();
}

// -------------------- MQTT (giống iot_class) --------------------
void mqttPub(const char *dev, const char *payload) {
  if (!mqttInited || !mqttClient.isConnected()) return;
  char topic[80];
  snprintf(topic, sizeof(topic), "tele/%s/status", dev);
  mqttClient.publish(topic, payload, false, 0);
  // Không Serial từng topic — in log làm chậm loop, dễ miss LoRa
}

void publishOnline() {
  mqttPub(cfgChipId, "online");
}

void publishTelemetry() {
  if (!node.valid) return;
  char buf[64];

  // Publish gọn, chỉ pump WS 1 lần giữa chừng — tránh block LoRa RX
  snprintf(buf, sizeof(buf), "{\"value\":%.1f}", node.water);
  mqttPub(DEV_WATER, buf);
  snprintf(buf, sizeof(buf), "{\"value\":%.1f}", node.soil);
  mqttPub(DEV_SOIL, buf);
  wsClient.loop();

  snprintf(buf, sizeof(buf), "{\"value\":%.2f}", node.roll);
  mqttPub(DEV_ROLL, buf);
  snprintf(buf, sizeof(buf), "{\"value\":%.2f}", node.pitch);
  mqttPub(DEV_PITCH, buf);

  snprintf(buf, sizeof(buf), "{\"value\":%.3f}", node.ax);
  mqttPub(DEV_AX, buf);
  snprintf(buf, sizeof(buf), "{\"value\":%.3f}", node.ay);
  mqttPub(DEV_AY, buf);
  snprintf(buf, sizeof(buf), "{\"value\":%.3f}", node.az);
  mqttPub(DEV_AZ, buf);

  bool loraLink = (millis() - node.lastRxMs < LORA_STALE_MS);
  mqttPub(DEV_LORA, loraLink ? "{\"value\":\"ONLINE\"}" : "{\"value\":\"OFFLINE\"}");
  wsClient.loop();
}

void publishAlarm(const char *type, const char *title, const char *body, bool on) {
  char buf[280];
  if (on) {
    snprintf(buf, sizeof(buf),
             "{\"value\":\"ON\",\"type\":\"%s\",\"title\":\"%s\",\"body\":\"%s\","
             "\"water\":%.1f,\"soil\":%.1f,\"roll\":%.1f,\"pitch\":%.1f}",
             type, title, body, node.water, node.soil, node.roll, node.pitch);
  } else {
    snprintf(buf, sizeof(buf), "{\"value\":\"OFF\",\"type\":\"%s\"}", type);
  }
  mqttPub(DEV_ALARM, buf);
}

void initMqtt() {
  if (mqttInited) return;
  int port = atoi(cfgMqttPort);
  if (port <= 0) port = 443;
  Serial.printf("[MQTT] WSS %s:%d%s\n", cfgMqttHost, port, MQTT_PATH);
  wsClient.beginSSL(cfgMqttHost, port, MQTT_PATH);
  wsClient.setExtraHeaders("Sec-WebSocket-Protocol: mqtt");
  wsClient.setReconnectInterval(5000);
  mqttClient.begin(wsClient);
  mqttInited = true;
}

void connectMqtt() {
  if (!mqttInited || mqttClient.isConnected()) return;
  if (WiFi.status() != WL_CONNECTED) return;

  uint32_t mac = (uint32_t)ESP.getEfuseMac();
  char clientId[28];
  snprintf(clientId, sizeof(clientId), "satlo-%08X", mac);
  char willTopic[64];
  snprintf(willTopic, sizeof(willTopic), "tele/%s/status", cfgChipId);

  Serial.printf("[MQTT] connect %s ...\n", clientId);
  mqttClient.setWill(willTopic, "offline", true, 1);
  if (!mqttClient.connect(clientId, "", "")) {
    Serial.println(F("[MQTT] WS chua san sang"));
    mqttOk = false;
    return;
  }
  Serial.println(F("[MQTT] OK (WSS)"));
  mqttOk = true;
  publishOnline();
  if (node.valid) publishTelemetry();
}

void ensureMqtt(uint32_t now) {
  if (!mqttInited) {
    if (WiFi.status() == WL_CONNECTED) initMqtt();
    return;
  }

  wsClient.loop();
  mqttClient.update();
  mqttOk = mqttClient.isConnected();

  if (!mqttOk && (now - lastMqttTryMs >= MQTT_RETRY_MS)) {
    lastMqttTryMs = now;
    connectMqtt();
  }

  if (mqttOk && (now - lastHeartMs >= HEART_MS)) {
    lastHeartMs = now;
    publishOnline();
  }
}

// -------------------- WIFI PORTAL --------------------
void startConfigPortal(bool forcePortal) {
  WiFiManagerParameter p_chip("chip", "Chip ID (vd SATLO_GW01)", cfgChipId, 31);
  WiFiManagerParameter p_host("mhost", "MQTT Host", cfgMqttHost, 63);
  WiFiManagerParameter p_port("mport", "MQTT Port (443 WSS)", cfgMqttPort, 7);

  wm.addParameter(&p_chip);
  wm.addParameter(&p_host);
  wm.addParameter(&p_port);
  wm.setConfigPortalTimeout(180);
  wm.setConnectTimeout(20);
  wm.setBreakAfterConfig(true);

  bool ok;
  if (forcePortal) ok = wm.startConfigPortal("SATLO-Gateway-Setup", "12345678");
  else ok = wm.autoConnect("SATLO-Gateway-Setup", "12345678");

  strncpy(cfgChipId, p_chip.getValue(), sizeof(cfgChipId) - 1);
  strncpy(cfgMqttHost, p_host.getValue(), sizeof(cfgMqttHost) - 1);
  strncpy(cfgMqttPort, p_port.getValue(), sizeof(cfgMqttPort) - 1);
  saveCfg();

  wifiOk = (WiFi.status() == WL_CONNECTED) || ok;
  Serial.printf("[WIFI] %s IP=%s chip=%s\n",
                WiFi.status() == WL_CONNECTED ? "OK" : "FAIL",
                WiFi.localIP().toString().c_str(), cfgChipId);
}

void ensureWifi(uint32_t now) {
  // Không block LoRa: chỉ gọi reconnect ngắn, không delay chờ
  wifiOk = (WiFi.status() == WL_CONNECTED);
  if (wifiOk) return;
  if (now - lastWifiTryMs < WIFI_RETRY_MS) return;
  lastWifiTryMs = now;
  Serial.println(F("[WIFI] soft reconnect (LoRa van chay)"));
  WiFi.reconnect();
}

void checkBootButton(uint32_t now) {
  bool pressed = digitalRead(PIN_BOOT) == LOW;
  if (pressed && !bootHolding) {
    bootHolding = true;
    bootHoldStart = now;
  } else if (pressed && bootHolding && now - bootHoldStart >= 3000) {
    bootHolding = false;
    Serial.println(F("[WIFI] BOOT held -> portal"));
    if (oledOk) {
      display.clearDisplay();
      display.setCursor(0, 0);
      display.setTextSize(1);
      display.println(F("WiFi Portal"));
      display.println(F("SATLO-Gateway-Setup"));
      display.println(F("Pass: 12345678"));
      display.display();
    }
    buzzOn(200);
    mqttInited = false;
    startConfigPortal(true);
    lastMqttTryMs = 0;
  } else if (!pressed) {
    bootHolding = false;
  }
}

// -------------------- LORA --------------------
uint8_t readLoRaReg(uint8_t reg) {
  digitalWrite(LORA_NSS, LOW);
  spiLoRa.beginTransaction(SPISettings(LORA_SPI_HZ, MSBFIRST, SPI_MODE0));
  spiLoRa.transfer(reg & 0x7F);
  uint8_t v = spiLoRa.transfer(0x00);
  spiLoRa.endTransaction();
  digitalWrite(LORA_NSS, HIGH);
  return v;
}

bool initLoRa() {
  pinMode(LORA_NSS, OUTPUT);
  digitalWrite(LORA_NSS, HIGH);
  pinMode(LORA_RST, OUTPUT);
  digitalWrite(LORA_RST, HIGH);
  delay(10);
  digitalWrite(LORA_RST, LOW);
  delay(10);
  digitalWrite(LORA_RST, HIGH);
  delay(50);

  spiLoRa.begin(LORA_SCK, LORA_MISO, LORA_MOSI, LORA_NSS);
  LoRa.setSPI(spiLoRa);
  LoRa.setSPIFrequency(LORA_SPI_HZ);
  LoRa.setPins(LORA_NSS, LORA_RST, LORA_DIO0);

  if (readLoRaReg(REG_VERSION) != 0x12) return false;
  if (!LoRa.begin(LORA_FREQ)) return false;
  LoRa.setSpreadingFactor(7);
  LoRa.setSignalBandwidth(125E3);
  LoRa.setCodingRate4(5);
  LoRa.enableCrc();
  LoRa.setSyncWord(LORA_SYNCWORD);
  LoRa.receive();  // luôn ở RX liên tục
  return true;
}

bool parseNodePacket(const char *msg, NodeData &out) {
  if (!msg || strncmp(msg, "NODE,", 5) != 0) return false;
  float f[16] = {0};
  int n = sscanf(msg,
                 "NODE,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f",
                 &f[0], &f[1], &f[2], &f[3], &f[4], &f[5], &f[6], &f[7],
                 &f[8], &f[9], &f[10], &f[11], &f[12], &f[13], &f[14]);
  if (n < 13) return false;
  if (n < 15) { f[13] = 0; f[14] = 0; }

  out.valid = true;
  out.nodeId = (uint32_t)f[0];
  out.seq = (uint32_t)f[1];
  out.water = f[2];
  out.soil = f[3];
  out.rainFlag = (int)f[4];
  out.soilDry = (int)f[5];
  out.roll = f[6];
  out.pitch = f[7];
  out.ax = f[8];
  out.ay = f[9];
  out.az = f[10];
  out.impact = (int)f[11];
  out.tilt = (int)f[12];
  out.landslide = (int)f[13];
  out.wetRisk = (int)f[14];
  return true;
}

void handleAlertsEdgeSync(uint32_t now) {
  if (buzzUntilMs && now >= buzzUntilMs) buzzOff();
  if (!node.valid) return;

  if (node.landslide) {
    if (now - lastBuzzMs >= 1000) { buzzOn(600); lastBuzzMs = now; }
    if (!lastAlertLandslide) {
      publishAlarm("SAT_LO", "Canh bao sat lo!",
                   "Rung/nghieng + am/nuoc cao - kiem tra ngay", true);
      lastAlertLandslide = 1;
    }
  } else if (lastAlertLandslide) {
    publishAlarm("SAT_LO", "", "", false);
    lastAlertLandslide = 0;
  }

  if (node.wetRisk && !node.landslide) {
    if (now - lastBuzzMs >= 1500) { buzzOn(350); lastBuzzMs = now; }
    if (!lastAlertWet) {
      publishAlarm("WET_RISK", "Canh bao nguy co lu!",
                   "Luong mua va do am dat cao - nguy co ngap/lu", true);
      lastAlertWet = 1;
    }
  } else if (!node.wetRisk && lastAlertWet) {
    publishAlarm("WET_RISK", "", "", false);
    lastAlertWet = 0;
  }

  if (node.impact && !node.landslide) {
    if (now - lastBuzzMs >= 700) { buzzOn(200); lastBuzzMs = now; }
    if (!lastAlertImpact) {
      publishAlarm("IMPACT", "Canh bao rung lac",
                   "IMU phat hien va dap/rung", true);
      lastAlertImpact = 1;
    }
  } else if (!node.impact && lastAlertImpact) {
    publishAlarm("IMPACT", "", "", false);
    lastAlertImpact = 0;
  }

  if (node.tilt && !node.landslide && !node.impact) {
    if (now - lastBuzzMs >= 1200) { buzzOn(120); lastBuzzMs = now; }
    if (!lastAlertTilt) {
      publishAlarm("TILT", "Canh bao nghieng",
                   "Goc nghieng vuot nguong", true);
      lastAlertTilt = 1;
    }
  } else if (!node.tilt && lastAlertTilt) {
    publishAlarm("TILT", "", "", false);
    lastAlertTilt = 0;
  }
}

void handleLoRaRx() {
  // Drain toàn bộ gói đang chờ — KHÔNG publish MQTT ở đây (tránh miss gói kế)
  for (;;) {
    int n = LoRa.parsePacket();
    if (n <= 0) break;

    char msg[220];
    int i = 0;
    while (LoRa.available() && i < (int)sizeof(msg) - 1) {
      msg[i++] = (char)LoRa.read();
    }
    msg[i] = 0;
    rxCount++;

    NodeData parsed;
    if (!parseNodePacket(msg, parsed)) continue;
    parsed.rssi = LoRa.packetRssi();
    parsed.snr = LoRa.packetSnr();
    parsed.lastRxMs = millis();
    node = parsed;
    telemetryPending = true;
    lastUiMs = 0;  // vẽ OLED ngay vòng sau

    Serial.printf("[LORA] seq=%lu W=%.1f S=%.1f rssi=%d L=%d WET=%d\n",
                  (unsigned long)node.seq, node.water, node.soil,
                  parsed.rssi, node.landslide, node.wetRisk);
  }
  // Giữ chip ở chế độ nhận sau khi đọc
  LoRa.receive();
}

// -------------------- OLED --------------------
bool initOled() {
  Wire.begin(I2C_SDA, I2C_SCL);
  if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR)) {
    if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3D)) return false;
  }
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(1);
  display.setCursor(0, 0);
  display.println(F("SATLO Gateway"));
  display.display();
  return true;
}

void drawUi() {
  if (!oledOk) return;
  display.clearDisplay();
  display.setTextSize(1);
  display.setTextColor(SSD1306_WHITE);
  display.setCursor(0, 0);

  // Chỉ trạng thái LoRa + MQTT (mất mạng vẫn hiện, không ảnh hưởng LoRa)
  bool loraLink = loraOk && node.valid && (millis() - node.lastRxMs < LORA_STALE_MS);
  display.printf("LoRa : %s\n", !loraOk ? "FAIL" : (loraLink ? "ONLINE" : "WAIT"));
  display.printf("MQTT : %s\n", mqttOk ? "ONLINE" : "OFFLINE");

  if (!node.valid) {
    display.println(F("Cho edge node..."));
  } else {
    display.printf("Luong mua: %4.1f%%\n", node.water);
    display.printf("Do am dat: %4.1f%%\n", node.soil);
    display.printf("X:%.2f Y:%.2f Z:%.2f\n", node.ax, node.ay, node.az);
    display.printf("R:%.0f P:%.0f ", node.roll, node.pitch);
    if (node.landslide) display.println(F("SATLO"));
    else if (node.wetRisk) display.println(F("AMCAO"));
    else if (node.impact) display.println(F("RUNG"));
    else if (node.tilt) display.println(F("NGHIENG"));
    else display.println(F("OK"));
  }
  display.display();
}

// -------------------- SETUP / LOOP --------------------
void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println(F("\n=== SATLO GATEWAY ==="));
  Serial.println(F("LoRa local doc lap | MQTT chi day dien thoai"));

  pinMode(PIN_BOOT, INPUT_PULLUP);
  buzzerInit();
  buzzOn(120); delay(150); buzzOff();

  loadCfg();

  // 1) LoRa + OLED trước — luôn dùng được dù không có mạng
  oledOk = initOled();
  loraOk = initLoRa();
  if (oledOk) {
    display.clearDisplay();
    display.setCursor(0, 0);
    display.printf("LoRa: %s\n", loraOk ? "OK" : "FAIL");
    display.println(F("MQTT: ..."));
    display.println(F("Dang thu WiFi"));
    display.display();
  }

  // 2) WiFi: thử mạng đã lưu, KHÔNG ép portal nếu fail (tránh treo LoRa)
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.persistent(true);
  wm.setEnableConfigPortal(false);   // không tự mở portal khi mất WiFi
  wm.setConnectTimeout(12);
  bool wifiConnected = wm.autoConnect("SATLO-Gateway-Setup", "12345678");

  // Chỉ mở portal lần đầu khi chưa từng lưu WiFi
  if (!wifiConnected && !wm.getWiFiIsSaved()) {
    if (oledOk) {
      display.clearDisplay();
      display.setCursor(0, 0);
      display.println(F("Cau hinh WiFi"));
      display.println(F("SATLO-Gateway-Setup"));
      display.println(F("Pass: 12345678"));
      display.display();
    }
    wm.setEnableConfigPortal(true);
    startConfigPortal(true);
  } else {
    // vẫn lấy tham số chip/mqtt từ NVS (đã loadCfg)
    wifiOk = (WiFi.status() == WL_CONNECTED);
  }

  // 3) MQTT chỉ khi có WiFi — fail cũng không ảnh hưởng LoRa/còi/OLED
  if (WiFi.status() == WL_CONNECTED) {
    wifiOk = true;
    initMqtt();
    connectMqtt();
  } else {
    wifiOk = false;
    mqttOk = false;
    Serial.println(F("[NET] Mat mang - LoRa/OLED/coi van chay"));
  }

  if (oledOk) {
    display.clearDisplay();
    display.setCursor(0, 0);
    display.printf("LoRa: %s\n", loraOk ? "OK" : "FAIL");
    display.printf("MQTT: %s\n", mqttOk ? "ONLINE" : "OFFLINE");
    display.println(F("Giu BOOT=portal"));
    display.display();
    delay(800);
  }

  Serial.println(F("Topics (chi khi MQTT online):"));
  Serial.printf("  tele/%s/status\n", cfgChipId);
  Serial.printf("  tele/%s/status (alarm->phone)\n", DEV_ALARM);
}

void loop() {
  uint32_t now = millis();

  // 1) LoRa trước hết — drain nhanh, không phụ thuộc MQTT
  if (loraOk) handleLoRaRx();
  handleAlertsEdgeSync(now);  // còi local; alarm MQTT thưa, best-effort

  if (now - lastUiMs >= UI_MS) {
    lastUiMs = now;
    drawUi();
  }

  // 2) Poll LoRa lại trước khi đụng mạng (OLED/I2C có thể chiếm vài ms)
  if (loraOk) handleLoRaRx();

  checkBootButton(now);
  ensureWifi(now);
  ensureMqtt(now);

  // 3) MQTT telemetry xếp hàng — chỉ khi có gói mới + đủ khoảng cách
  if (mqttOk && node.valid && telemetryPending &&
      (now - lastTelemetryMs >= TELEMETRY_MS)) {
    lastTelemetryMs = now;
    telemetryPending = false;
    publishTelemetry();
    // Sau burst MQTT, drain LoRa ngay kẻo miss gói trong lúc publish
    if (loraOk) handleLoRaRx();
  }
}
