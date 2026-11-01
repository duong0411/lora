/**
 * LoRa SX1278 433MHz - CODE TEST NHẬN (RX) - ESP32
 * Dùng board thứ 2 để nghe packet từ lora_sx1278_test (TX)
 *
 * Thư viện: LoRa by Sandeep Mistry
 * Serial: 115200
 * Cùng chân đấu với bản TX.
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

SPIClass spiLoRa(HSPI);
uint32_t rxCount = 0;

uint8_t readReg(uint8_t reg) {
  digitalWrite(LORA_NSS, LOW);
  spiLoRa.beginTransaction(SPISettings(SPI_HZ, MSBFIRST, SPI_MODE0));
  spiLoRa.transfer(reg & 0x7F);
  uint8_t v = spiLoRa.transfer(0x00);
  spiLoRa.endTransaction();
  digitalWrite(LORA_NSS, HIGH);
  return v;
}

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println(F("=== LoRa SX1278 TEST (RX) ==="));

  pinMode(LORA_NSS, OUTPUT);
  digitalWrite(LORA_NSS, HIGH);

  spiLoRa.begin(LORA_SCK, LORA_MISO, LORA_MOSI, LORA_NSS);
  LoRa.setSPI(spiLoRa);
  LoRa.setSPIFrequency(SPI_HZ);
  LoRa.setPins(LORA_NSS, LORA_RST, LORA_DIO0);

  uint8_t ver = readReg(REG_VERSION);
  Serial.printf("[RX] VERSION=0x%02X (can 0x12)\n", ver);

  if (!LoRa.begin(LORA_FREQ)) {
    Serial.println(F("[RX] begin FAIL - kiem tra day"));
    while (true) delay(1000);
  }

  LoRa.setSpreadingFactor(7);
  LoRa.setSignalBandwidth(125E3);
  LoRa.setCodingRate4(5);
  LoRa.enableCrc();
  LoRa.setSyncWord(0x12);

  Serial.println(F("[RX] listening..."));
}

void loop() {
  int n = LoRa.parsePacket();
  if (n <= 0) return;

  String msg;
  while (LoRa.available()) {
    msg += (char)LoRa.read();
  }
  rxCount++;
  Serial.printf("[RX] #%lu RSSI=%d SNR=%.1f len=%d | %s\n",
                (unsigned long)rxCount, LoRa.packetRssi(), LoRa.packetSnr(), n, msg.c_str());
}
