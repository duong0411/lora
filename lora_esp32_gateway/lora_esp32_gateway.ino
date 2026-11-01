/**
 * ESP32 LoRa GATEWAY (nhận)
 * - LoRa SY SX1278 433MHz
 * - OLED 0.96" SSD1306 I2C SDA=21 SCL=22
 * - Còi GPIO13
 *
 * Nhận packet từ lora_esp32_node:
 * NODE,id,seq,waterPct,soilMoistPct,rainFlag,soilDryFlag,roll,pitch,ax,ay,az,impact,tilt,landslide,wetRisk
 *
 * Thư viện:
 *  - LoRa (Sandeep Mistry)
 *  - Adafruit SSD1306
 *  - Adafruit GFX
 */

#include <SPI.h>
#include <Wire.h>
#include <LoRa.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

// ===================== PIN =====================
#define LORA_NSS   5
#define LORA_RST   4
#define LORA_DIO0  25
#define LORA_SCK   18
#define LORA_MISO  19
#define LORA_MOSI  23

#define PIN_BUZZER 13
#define I2C_SDA    21
#define I2C_SCL    22

#define SCREEN_WIDTH  128
#define SCREEN_HEIGHT 64
#define OLED_ADDR     0x3C

#define LORA_FREQ     433E6
#define LORA_SPI_HZ   1000000UL
#define REG_VERSION   0x42

#define BUZZER_CH     0
#define BUZZER_FREQ   2700
#define UI_REFRESH_MS 300

SPIClass spiLoRa(HSPI);
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, -1);

struct NodeData {
  bool     valid;
  uint32_t nodeId;
  uint32_t seq;
  float    waterPct;
  float    soilPct;
  int      rainFlag;
  int      soilDryFlag;
  float    roll;
  float    pitch;
  float    ax, ay, az;
  int      impact;
  int      tilt;
  int      landslide;
  int      wetRisk;
  int      rssi;
  float    snr;
  uint32_t lastRxMs;
};

NodeData node = {};
uint32_t rxCount = 0;
uint32_t lastUiMs = 0;
uint32_t buzzUntilMs = 0;
uint32_t lastBuzzMs = 0;
bool oledOk = false;
bool loraOk = false;

void buzzOff() {
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWriteTone(PIN_BUZZER, 0);
  ledcWrite(PIN_BUZZER, 0);
#else
  ledcWriteTone(BUZZER_CH, 0);
  ledcWrite(BUZZER_CH, 0);
#endif
  buzzUntilMs = 0;
}

void buzzOn(uint32_t ms) {
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWriteTone(PIN_BUZZER, BUZZER_FREQ);
#else
  ledcWriteTone(BUZZER_CH, BUZZER_FREQ);
  ledcWrite(BUZZER_CH, 160);
#endif
  buzzUntilMs = millis() + ms;
}

void buzzerInit() {
  pinMode(PIN_BUZZER, OUTPUT);
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcAttach(PIN_BUZZER, BUZZER_FREQ, 8);
  ledcWrite(PIN_BUZZER, 0);
#else
  ledcSetup(BUZZER_CH, BUZZER_FREQ, 8);
  ledcAttachPin(PIN_BUZZER, BUZZER_CH);
  ledcWrite(BUZZER_CH, 0);
#endif
}

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

  uint8_t ver = readLoRaReg(REG_VERSION);
  Serial.printf("[LORA] VERSION=0x%02X (can 0x12)\n", ver);
  if (ver != 0x12) {
    Serial.println(F("[LORA] SPI FAIL - kiem tra day"));
    return false;
  }

  if (!LoRa.begin(LORA_FREQ)) {
    Serial.println(F("[LORA] begin FAIL"));
    return false;
  }

  LoRa.setSpreadingFactor(7);
  LoRa.setSignalBandwidth(125E3);
  LoRa.setCodingRate4(5);
  LoRa.enableCrc();
  LoRa.setSyncWord(0x12);

  Serial.println(F("[LORA] RX READY 433MHz"));
  return true;
}

bool initOled() {
  Wire.begin(I2C_SDA, I2C_SCL);
  if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR)) {
    Serial.println(F("[OLED] khong tim thay 0x3C, thu 0x3D..."));
    if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3D)) {
      Serial.println(F("[OLED] FAIL"));
      return false;
    }
  }
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(1);
  display.setCursor(0, 0);
  display.println(F("LoRa Gateway"));
  display.println(F("Waiting node..."));
  display.display();
  Serial.println(F("[OLED] OK"));
  return true;
}

bool parseNodePacket(const String &msg, NodeData &out) {
  // NODE,id,seq,water,soil,rainFlag,soilDry,roll,pitch,ax,ay,az,impact,tilt,landslide,wetRisk
  if (!msg.startsWith("NODE,")) return false;

  float f[16];
  int n = sscanf(msg.c_str(),
                 "NODE,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f",
                 &f[0], &f[1], &f[2], &f[3], &f[4], &f[5], &f[6], &f[7],
                 &f[8], &f[9], &f[10], &f[11], &f[12], &f[13], &f[14]);

  // tối thiểu cần water,soil + flags cuối
  if (n < 14) {
    // tương thích gói cũ ngắn hơn
    n = sscanf(msg.c_str(),
               "NODE,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f",
               &f[0], &f[1], &f[2], &f[3], &f[4], &f[5], &f[6], &f[7],
               &f[8], &f[9], &f[10], &f[11], &f[12]);
    if (n < 13) return false;
    f[13] = 0;  // landslide
    f[14] = 0;  // wetRisk
  }

  out.valid = true;
  out.nodeId = (uint32_t)f[0];
  out.seq = (uint32_t)f[1];
  out.waterPct = f[2];
  out.soilPct = f[3];
  out.rainFlag = (int)f[4];
  out.soilDryFlag = (int)f[5];
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

void updateAlertBuzzer(uint32_t now) {
  if (buzzUntilMs != 0 && now >= buzzUntilMs) {
    buzzOff();
  }

  if (!node.valid) return;

  // Ưu tiên: sạt lở > impact > wetRisk > tilt
  if (node.landslide) {
    if (now - lastBuzzMs >= 900) {
      buzzOn(500);
      lastBuzzMs = now;
      Serial.println(F("[ALERT] SAT_LO buzzer"));
    }
  } else if (node.impact) {
    if (now - lastBuzzMs >= 600) {
      buzzOn(200);
      lastBuzzMs = now;
    }
  } else if (node.wetRisk) {
    if (now - lastBuzzMs >= 1500) {
      buzzOn(250);
      lastBuzzMs = now;
    }
  } else if (node.tilt) {
    if (now - lastBuzzMs >= 1200) {
      buzzOn(120);
      lastBuzzMs = now;
    }
  }
}

void drawUi() {
  display.clearDisplay();
  display.setTextSize(1);
  display.setTextColor(SSD1306_WHITE);
  display.setCursor(0, 0);

  if (!loraOk) {
    display.println(F("LoRa FAIL"));
    display.println(F("Check wiring"));
    display.display();
    return;
  }

  if (!node.valid) {
    display.println(F("GATEWAY RX"));
    display.println(F("Cho tin hieu..."));
    display.printf("RX=%lu\n", (unsigned long)rxCount);
    display.display();
    return;
  }

  uint32_t age = (millis() - node.lastRxMs) / 1000UL;
  display.printf("Node%lu #%lu %lus\n",
                 (unsigned long)node.nodeId,
                 (unsigned long)node.seq,
                 (unsigned long)age);

  display.printf("Nuoc:%4.0f%% Dat:%4.0f%%\n", node.waterPct, node.soilPct);
  display.printf("Roll:%5.1f Pit:%5.1f\n", node.roll, node.pitch);
  display.printf("RSSI:%d SNR:%.1f\n", node.rssi, node.snr);

  // Dòng cảnh báo
  if (node.landslide) {
    display.println(F("!! SAT LO !!"));
  } else if (node.wetRisk) {
    display.println(F("CANH BAO AM/NUOC"));
  } else if (node.impact) {
    display.println(F("RUNG / VA DAP"));
  } else if (node.tilt) {
    display.println(F("NGHIENG"));
  } else {
    display.println(F("Trang thai: OK"));
  }

  display.printf("I%d T%d W%d L%d\n",
                 node.impact, node.tilt, node.wetRisk, node.landslide);
  display.display();
}

void handleRx() {
  int packetSize = LoRa.parsePacket();
  if (packetSize <= 0) return;

  String msg;
  msg.reserve(packetSize + 1);
  while (LoRa.available()) {
    msg += (char)LoRa.read();
  }

  rxCount++;
  int rssi = LoRa.packetRssi();
  float snr = LoRa.packetSnr();

  Serial.printf("[RX] #%lu RSSI=%d SNR=%.1f | %s\n",
                (unsigned long)rxCount, rssi, snr, msg.c_str());

  NodeData parsed = {};
  if (parseNodePacket(msg, parsed)) {
    parsed.rssi = rssi;
    parsed.snr = snr;
    parsed.lastRxMs = millis();
    node = parsed;

    Serial.printf("[DATA] W=%.1f S=%.1f wet=%d satLo=%d impact=%d tilt=%d\n",
                  node.waterPct, node.soilPct, node.wetRisk,
                  node.landslide, node.impact, node.tilt);
  } else if (msg.startsWith("LORA_TEST")) {
    // packet từ sketch test
    node.valid = true;
    node.nodeId = 0;
    node.seq = rxCount;
    node.waterPct = 0;
    node.soilPct = 0;
    node.rssi = rssi;
    node.snr = snr;
    node.lastRxMs = millis();
    Serial.println(F("[RX] got LORA_TEST packet"));
  } else {
    Serial.println(F("[RX] parse FAIL"));
  }
}

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println(F("\n=== ESP32 LoRa GATEWAY ==="));

  buzzerInit();
  buzzOn(150);
  delay(180);
  buzzOff();

  oledOk = initOled();
  loraOk = initLoRa();

  if (oledOk) {
    display.clearDisplay();
    display.setCursor(0, 0);
    display.println(F("Gateway boot"));
    display.printf("LoRa:%s\n", loraOk ? "OK" : "FAIL");
    display.printf("OLED SDA%d SCL%d\n", I2C_SDA, I2C_SCL);
    display.printf("Buzz: GPIO%d\n", PIN_BUZZER);
    display.display();
  }

  if (!loraOk) {
    for (int i = 0; i < 4; i++) {
      buzzOn(80); delay(100); buzzOff(); delay(80);
    }
  }
}

void loop() {
  uint32_t now = millis();

  if (loraOk) handleRx();
  updateAlertBuzzer(now);

  if (now - lastUiMs >= UI_REFRESH_MS) {
    lastUiMs = now;
    if (oledOk) drawUi();
  }
}
