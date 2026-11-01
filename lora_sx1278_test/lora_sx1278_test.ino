/**
 * LoRa SX1278 433MHz - CODE TEST RIÊNG (ESP32)
 * Module: SY SX1278 / Ra-02
 *
 * Thư viện: LoRa by Sandeep Mistry
 * Board: ESP32 Dev Module
 * Serial: 115200
 *
 * Mục tiêu:
 *  1) Đọc VERSION chip (phải = 0x12)
 *  2) Test SPI ghi/đọc
 *  3) Gửi packet định kỳ (TX)
 *
 * Đấu dây:
 *  VCC/3.3V -> 3V3
 *  GND      -> GND
 *  NSS/CS   -> GPIO5
 *  RST      -> GPIO4
 *  DIO0     -> GPIO25
 *  SCK      -> GPIO18
 *  MISO     -> GPIO19
 *  MOSI     -> GPIO23
 *  ANT      -> anten 433MHz
 */

#include <SPI.h>
#include <LoRa.h>

#define LORA_NSS   5
#define LORA_RST   4
#define LORA_DIO0  25
#define LORA_SCK   18
#define LORA_MISO  19
#define LORA_MOSI  23

#define LORA_FREQ  433E6
#define SPI_HZ     1000000UL
#define REG_VERSION 0x42
#define TX_EVERY_MS 2000

SPIClass spiLoRa(HSPI);
uint32_t seq = 0;
uint32_t lastTxMs = 0;
uint32_t txOk = 0;
uint32_t txFail = 0;

void hardReset() {
  pinMode(LORA_RST, OUTPUT);
  digitalWrite(LORA_NSS, HIGH);
  digitalWrite(LORA_RST, HIGH);
  delay(10);
  digitalWrite(LORA_RST, LOW);
  delay(10);
  digitalWrite(LORA_RST, HIGH);
  delay(50);
}

uint8_t readReg(uint8_t reg) {
  digitalWrite(LORA_NSS, LOW);
  spiLoRa.beginTransaction(SPISettings(SPI_HZ, MSBFIRST, SPI_MODE0));
  spiLoRa.transfer(reg & 0x7F);
  uint8_t v = spiLoRa.transfer(0x00);
  spiLoRa.endTransaction();
  digitalWrite(LORA_NSS, HIGH);
  return v;
}

void writeReg(uint8_t reg, uint8_t val) {
  digitalWrite(LORA_NSS, LOW);
  spiLoRa.beginTransaction(SPISettings(SPI_HZ, MSBFIRST, SPI_MODE0));
  spiLoRa.transfer(reg | 0x80);
  spiLoRa.transfer(val);
  spiLoRa.endTransaction();
  digitalWrite(LORA_NSS, HIGH);
}

void printWiring() {
  Serial.println(F("---- WIRING SX1278 ----"));
  Serial.println(F("NSS/CS->5  RST->4  DIO0->25"));
  Serial.println(F("SCK->18  MISO->19  MOSI->23"));
  Serial.println(F("VCC->3V3  GND->GND  + ANT"));
  Serial.println(F("-----------------------"));
}

bool probeChip() {
  Serial.println(F("[TEST] SPI probe..."));
  bool ok = false;
  for (int i = 0; i < 5; i++) {
    uint8_t ver = readReg(REG_VERSION);
    Serial.printf("[TEST] VERSION[%d]=0x%02X", i, ver);
    if (ver == 0x12) {
      Serial.println(F("  OK (SX1278)"));
      ok = true;
    } else if (ver == 0x00 || ver == 0xFF) {
      Serial.println(F("  BAD (sai day/nguon/SPI)"));
    } else {
      Serial.println(F("  UNEXPECTED"));
    }
    delay(20);
  }

  uint8_t oldv = readReg(0x39);
  writeReg(0x39, 0xA5);
  delay(2);
  uint8_t rd = readReg(0x39);
  writeReg(0x39, oldv);
  Serial.printf("[TEST] R/W syncWord: wrote=0xA5 read=0x%02X -> %s\n",
                rd, (rd == 0xA5) ? "PASS" : "FAIL");

  return ok && (rd == 0xA5);
}

bool initLoRa() {
  printWiring();

  pinMode(LORA_NSS, OUTPUT);
  digitalWrite(LORA_NSS, HIGH);
  pinMode(LORA_DIO0, INPUT);

  spiLoRa.begin(LORA_SCK, LORA_MISO, LORA_MOSI, LORA_NSS);
  LoRa.setSPI(spiLoRa);
  LoRa.setSPIFrequency(SPI_HZ);
  LoRa.setPins(LORA_NSS, LORA_RST, LORA_DIO0);

  hardReset();
  if (!probeChip()) {
    Serial.println(F("[TEST] FAIL: chua thay SX1278 (can VERSION=0x12)"));
    return false;
  }

  if (!LoRa.begin(LORA_FREQ)) {
    Serial.println(F("[TEST] LoRa.begin(433E6) FAIL"));
    return false;
  }

  LoRa.setSpreadingFactor(7);
  LoRa.setSignalBandwidth(125E3);
  LoRa.setCodingRate4(5);
  LoRa.setTxPower(17);
  LoRa.enableCrc();
  LoRa.setSyncWord(0x12);

  Serial.println(F("[TEST] LoRa READY - se TX moi 2 giay"));
  return true;
}

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println();
  Serial.println(F("=== LoRa SX1278 TEST (TX) ==="));

  if (!initLoRa()) {
    Serial.println(F("Dung lai. Kiem tra day roi Reset lai board."));
    while (true) {
      delay(1000);
      uint8_t ver = readReg(REG_VERSION);
      Serial.printf("[TEST] retry VERSION=0x%02X (can 0x12)\n", ver);
    }
  }

  lastTxMs = millis();
}

void loop() {
  uint32_t now = millis();
  if (now - lastTxMs < TX_EVERY_MS) return;
  lastTxMs = now;

  seq++;
  char msg[64];
  snprintf(msg, sizeof(msg), "LORA_TEST,seq=%lu,hello", (unsigned long)seq);

  Serial.printf("[TX] %s ... ", msg);
  uint32_t t0 = millis();
  LoRa.beginPacket();
  LoRa.print(msg);
  bool ok = LoRa.endPacket();
  uint32_t dt = millis() - t0;

  if (ok) {
    txOk++;
    Serial.printf("OK (%lums) ok=%lu fail=%lu\n",
                  (unsigned long)dt, (unsigned long)txOk, (unsigned long)txFail);
  } else {
    txFail++;
    Serial.printf("FAIL (%lums) ok=%lu fail=%lu\n",
                  (unsigned long)dt, (unsigned long)txOk, (unsigned long)txFail);
  }
}
