/**
 * ESP32 LoRa Node Station
 * - LoRa Ra-02 (SPI)
 * - Cảm biến mưa AO GPIO32  -> mực nước / mức mưa (%)
 * - Cảm biến đất  AO GPIO33  -> độ ẩm đất (%)
 * - Buzzer GPIO13
 * - MPU6050 (I2C SDA21 / SCL22)
 *
 * Thuật toán cải thiện độ chính xác:
 * 1) Mưa / Đất (AO): multi-sample median + EMA + map hiệu chuẩn dry/wet + hysteresis %
 * 2) MPU6050: hiệu chuẩn offset, EMA, complementary filter (roll/pitch), phát hiện rung/va đập
 *
 * LƯU Ý ĐẤU DÂY: dùng chân AO (Analog Out), không dùng DO nếu muốn ra %.
 */

#include <SPI.h>
#include <Wire.h>
#include <stdlib.h>
#include <LoRa.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>

// ===================== PIN MAP =====================
#define LORA_NSS   5
#define LORA_RST   4
#define LORA_DIO0  25
#define LORA_SCK   18
#define LORA_MISO  19
#define LORA_MOSI  23

#define PIN_RAIN_AO  32   // AO cảm biến mưa -> mực nước %
#define PIN_SOIL_AO  33   // AO cảm biến đất  -> độ ẩm %
#define PIN_BUZZER   13   // + còi; - nối GND
#define BUZZER_CH    0    // LEDC channel (ESP32 Arduino 2.x)
#define BUZZER_FREQ_HZ 2700
#define BUZZER_DUTY    180  // 0..255 (âm lượng PWM)

#define I2C_SDA    21
#define I2C_SCL    22

// ===================== CẤU HÌNH LORA (SY SX1278 433MHz) =====================
#define LORA_FREQ_HZ      433E6   // SX1278 433 MHz
#define LORA_SF            7
#define LORA_BW            125E3
#define LORA_CR            5
#define LORA_TX_POWER_DBM  17
#define NODE_ID            1

#define SEND_INTERVAL_MS   1000   // ~1s/gói (như bản cũ)

// ===================== LOG Serial =====================
#define LOG_SENSOR_MS      1000   // chu kỳ in trạng thái cảm biến
#define LOG_VERBOSE        1      // 1: log chi tiết raw/filter; 0: gọn hơn
#define LORA_INIT_RETRIES  5
#define LORA_SPI_HZ        1000000UL  // 1 MHz — ổn định trên breadboard
#define REG_VERSION        0x42       // SX1278 = 0x12

// ===================== CẤU HÌNH CẢM BIẾN AO (ADC) =====================
// Module mưa/đất phổ biến: KHÔ = ADC cao, ƯỚT = ADC thấp (đảo khi map %).
// Hiệu chỉnh 2 điểm: đo Serial [RAIN]/[SOIL] adc=... khi khô và khi ướt, điền vào đây.
#define ANALOG_SAMPLE_MS     50
#define ANALOG_SAMPLES       11     // lấy median (số lẻ)
#define ANALOG_EMA_ALPHA     0.25f  // làm mượt %

#define RAIN_ADC_DRY         3200   // ADC khi khô / không nước
#define RAIN_ADC_WET         1200   // ADC khi ướt nhiều / mực cao
#define SOIL_ADC_DRY         3200   // ADC đất khô
#define SOIL_ADC_WET         1400   // ADC đất ướt

#define WATER_WET_ON_PCT     35.0f  // >= coi là có nước/mưa
#define WATER_WET_OFF_PCT    25.0f  // <= tắt cờ mưa (hysteresis)
#define SOIL_DRY_ON_PCT      30.0f  // <= coi đất khô
#define SOIL_DRY_OFF_PCT     40.0f  // >= hết cảnh báo khô

// ===================== CẤU HÌNH MPU6050 =====================
#define MPU_SAMPLE_MS      20
#define EMA_ALPHA          0.18f  // 0..1 — càng nhỏ càng mượt
#define COMP_FILTER_ALPHA  0.96f  // tỷ trọng gyro trong complementary filter
#define IMPACT_THRESHOLD_G 2.4f   // cao hơn — tránh nhiễu MPU khi để yên
#define TILT_ALERT_DEG     35.0f  // nghiêng rõ mới cảnh báo
// 0 = để yên không kêu vì rung/nghiêng (vẫn gửi flag qua LoRa)
// 1 = kêu cả impact/tilt (dễ ù khi bàn rung / nhiễu)
#define BUZZER_ON_MOTION   0
#define BUZZER_IMPACT_MS   180
#define BUZZER_ALERT_MS    80
#define BUZZER_WET_MS      350       // còi: nước + ẩm cao (đủ dài để nghe)
#define BUZZER_WET_GAP_MS  1200
#define BUZZER_LANDSLIDE_MS 600      // còi dài khi sạt lở
#define BUZZER_LANDSLIDE_GAP_MS 400

// ===================== CẢNH BÁO ẨM / SẠT LỞ =====================
// Mức 1 (WET_RISK): nước cao + ẩm đất cao -> còi cảnh báo
// Mức 2 (SAT_LO):  WET_RISK + (rung OR nghiêng) -> còi báo động
#define LANDSLIDE_WATER_PCT   50.0f   // mực nước / mưa >=
#define LANDSLIDE_SOIL_PCT    55.0f   // độ ẩm đất >= (đất ướt)
#define LANDSLIDE_TILT_DEG    25.0f   // nghiêng đủ để tính nguy cơ sạt lở
#define LANDSLIDE_SHAKE_G     0.45f   // |a|-1g đủ để tính rung (nhẹ hơn IMPACT)
#define LANDSLIDE_HOLD_MS     200     // giữ đủ điều kiện tối thiểu trước khi chốt
#define WET_RISK_HOLD_MS      300

Adafruit_MPU6050 mpu;
SPIClass spiLoRa(HSPI);  // bus SPI riêng cho SX1278, tránh xung đột

// ---- Analog sensor state ----
struct AnalogSensor {
  uint16_t adcRaw;     // ADC mới nhất (sau median)
  float    adcEma;     // ADC đã EMA
  float    percent;    // 0..100
  bool     flag;       // mưa=có nước / đất=khô
  bool     ready;
};

AnalogSensor rain = {};   // percent = mực nước / mức mưa
AnalogSensor soil = {};   // percent = độ ẩm đất

// ---- MPU state ----
struct MpuState {
  float ax, ay, az;       // gia tốc đã lọc (g)
  float gx, gy, gz;       // gyro đã lọc (deg/s)
  float roll, pitch;      // góc (deg)
  float axOff, ayOff, azOff;
  float gxOff, gyOff, gzOff;
  float accelMag;         // |a| (g)
  bool  impact;
  bool  tiltAlert;
  bool  ready;
};

MpuState imu = {};
uint32_t lastMpuMs = 0;
uint32_t lastAnalogMs = 0;
uint32_t lastSendMs = 0;
uint32_t lastBuzzMs = 0;
uint32_t buzzUntilMs = 0;
uint32_t lastSensorLogMs = 0;
uint32_t packetSeq = 0;
uint32_t txOkCount = 0;
uint32_t txFailCount = 0;
uint32_t loraInitAttempts = 0;
uint8_t  lastLoraVersion = 0x00;
bool loraReady = false;
bool lastRainFlag = false;
bool lastSoilDryFlag = false;
bool lastImpact = false;
bool lastTiltAlert = false;
bool wetRiskAlert = false;       // nước cao + ẩm cao
bool landslideAlert = false;     // wet + rung/nghiêng
bool lastWetRiskAlert = false;
bool lastLandslideAlert = false;
uint32_t wetRiskCondSinceMs = 0;
uint32_t landslideCondSinceMs = 0;

static int cmpU16(const void *a, const void *b) {
  uint16_t va = *(const uint16_t *)a;
  uint16_t vb = *(const uint16_t *)b;
  return (va > vb) - (va < vb);
}

uint16_t readAdcMedian(uint8_t pin, uint8_t samples) {
  if (samples < 1) samples = 1;
  if (samples > 31) samples = 31;
  uint16_t buf[31];
  for (uint8_t i = 0; i < samples; i++) {
    buf[i] = (uint16_t)analogRead(pin);
    delayMicroseconds(300);
  }
  qsort(buf, samples, sizeof(uint16_t), cmpU16);
  return buf[samples / 2];
}

// ADC khô cao / ướt thấp -> % ướt/mực nước 0..100
float adcToWetPercent(float adc, int adcDry, int adcWet) {
  if (adcDry == adcWet) return 0.0f;
  float pct = 100.0f * (float)(adcDry - adc) / (float)(adcDry - adcWet);
  if (pct < 0.0f) pct = 0.0f;
  if (pct > 100.0f) pct = 100.0f;
  return pct;
}

void updateAnalogSensor(AnalogSensor &s, uint8_t pin, int adcDry, int adcWet,
                        bool risingFlag, float onPct, float offPct, bool &lastFlag,
                        const char *tag, const char *onName, const char *offName) {
  uint16_t med = readAdcMedian(pin, ANALOG_SAMPLES);
  s.adcRaw = med;

  if (!s.ready) {
    s.adcEma = med;
    s.ready = true;
  } else {
    s.adcEma = ANALOG_EMA_ALPHA * med + (1.0f - ANALOG_EMA_ALPHA) * s.adcEma;
  }

  s.percent = adcToWetPercent(s.adcEma, adcDry, adcWet);

  // Hysteresis trạng thái
  if (!s.flag) {
    if ((risingFlag && s.percent >= onPct) || (!risingFlag && s.percent <= onPct)) {
      s.flag = true;
    }
  } else {
    if ((risingFlag && s.percent <= offPct) || (!risingFlag && s.percent >= offPct)) {
      s.flag = false;
    }
  }

  if (s.flag != lastFlag) {
    Serial.printf("[%s] change -> %s | adc=%u ema=%.0f pct=%.1f%%\n",
                  tag, s.flag ? onName : offName,
                  s.adcRaw, s.adcEma, s.percent);
    lastFlag = s.flag;
  }
}

void updateAnalogSensors(uint32_t nowMs) {
  if (nowMs - lastAnalogMs < ANALOG_SAMPLE_MS) return;
  lastAnalogMs = nowMs;

  // Mưa/mực nước: flag bật khi % tăng (có nước)
  updateAnalogSensor(rain, PIN_RAIN_AO, RAIN_ADC_DRY, RAIN_ADC_WET,
                     true, WATER_WET_ON_PCT, WATER_WET_OFF_PCT, lastRainFlag,
                     "RAIN", "CO_NUOC", "KHO");

  // Đất: percent = độ ẩm; flag = đất khô khi ẩm thấp
  updateAnalogSensor(soil, PIN_SOIL_AO, SOIL_ADC_DRY, SOIL_ADC_WET,
                     false, SOIL_DRY_ON_PCT, SOIL_DRY_OFF_PCT, lastSoilDryFlag,
                     "SOIL", "DAT_KHO", "DAT_AM");
}

bool calibrateMpu(uint16_t samples = 200) {
  float sax = 0, say = 0, saz = 0;
  float sgx = 0, sgy = 0, sgz = 0;
  uint16_t ok = 0;

  Serial.println(F("[MPU] Calibrating... keep device still"));
  for (uint16_t i = 0; i < samples; i++) {
    sensors_event_t a, g, temp;
    mpu.getEvent(&a, &g, &temp);

    sax += a.acceleration.x;
    say += a.acceleration.y;
    saz += a.acceleration.z;
    sgx += g.gyro.x;
    sgy += g.gyro.y;
    sgz += g.gyro.z;
    ok++;
    delay(5);
  }
  if (ok == 0) return false;

  // Gia tốc: offset = trung bình - trọng lực trên trục Z (giả sử đặt phẳng, Z hướng lên)
  imu.axOff = sax / ok;
  imu.ayOff = say / ok;
  imu.azOff = (saz / ok) - 9.80665f;
  // Gyro: offset = trung bình (đơn vị rad/s từ Adafruit)
  imu.gxOff = sgx / ok;
  imu.gyOff = sgy / ok;
  imu.gzOff = sgz / ok;
  imu.ready = true;

  Serial.printf("[MPU] Offsets ax=%.3f ay=%.3f az=%.3f | gx=%.4f gy=%.4f gz=%.4f\n",
                imu.axOff, imu.ayOff, imu.azOff, imu.gxOff, imu.gyOff, imu.gzOff);
  return true;
}

void updateMpu(uint32_t nowMs) {
  if (!imu.ready) return;
  if (nowMs - lastMpuMs < MPU_SAMPLE_MS) return;

  float dt = (nowMs - lastMpuMs) / 1000.0f;
  if (lastMpuMs == 0) dt = MPU_SAMPLE_MS / 1000.0f;
  lastMpuMs = nowMs;

  sensors_event_t a, g, temp;
  mpu.getEvent(&a, &g, &temp);

  // Bù offset, đổi accel sang g, gyro sang deg/s
  float axRaw = (a.acceleration.x - imu.axOff) / 9.80665f;
  float ayRaw = (a.acceleration.y - imu.ayOff) / 9.80665f;
  float azRaw = (a.acceleration.z - imu.azOff) / 9.80665f;
  float gxRaw = (g.gyro.x - imu.gxOff) * RAD_TO_DEG;
  float gyRaw = (g.gyro.y - imu.gyOff) * RAD_TO_DEG;
  float gzRaw = (g.gyro.z - imu.gzOff) * RAD_TO_DEG;

  // EMA làm mượt nhiễu
  imu.ax = EMA_ALPHA * axRaw + (1.0f - EMA_ALPHA) * imu.ax;
  imu.ay = EMA_ALPHA * ayRaw + (1.0f - EMA_ALPHA) * imu.ay;
  imu.az = EMA_ALPHA * azRaw + (1.0f - EMA_ALPHA) * imu.az;
  imu.gx = EMA_ALPHA * gxRaw + (1.0f - EMA_ALPHA) * imu.gx;
  imu.gy = EMA_ALPHA * gyRaw + (1.0f - EMA_ALPHA) * imu.gy;
  imu.gz = EMA_ALPHA * gzRaw + (1.0f - EMA_ALPHA) * imu.gz;

  // Góc từ accelerometer (ổn khi tĩnh, nhiễu khi động)
  float rollAcc  = atan2f(imu.ay, imu.az) * RAD_TO_DEG;
  float pitchAcc = atan2f(-imu.ax, sqrtf(imu.ay * imu.ay + imu.az * imu.az)) * RAD_TO_DEG;

  // Complementary filter: kết hợp gyro (nhanh) + accel (ổn lâu dài)
  imu.roll  = COMP_FILTER_ALPHA * (imu.roll  + imu.gx * dt) + (1.0f - COMP_FILTER_ALPHA) * rollAcc;
  imu.pitch = COMP_FILTER_ALPHA * (imu.pitch + imu.gy * dt) + (1.0f - COMP_FILTER_ALPHA) * pitchAcc;

  imu.accelMag = sqrtf(imu.ax * imu.ax + imu.ay * imu.ay + imu.az * imu.az);
  float impactG = fabsf(imu.accelMag - 1.0f);
  imu.impact = (impactG >= IMPACT_THRESHOLD_G);
  imu.tiltAlert = (fabsf(imu.roll) >= TILT_ALERT_DEG) || (fabsf(imu.pitch) >= TILT_ALERT_DEG);

  if (imu.impact && !lastImpact) {
    Serial.printf("[MPU] IMPACT |a|=%.3fg delta=%.3fg roll=%.1f pitch=%.1f\n",
                  imu.accelMag, impactG, imu.roll, imu.pitch);
  }
  if (imu.tiltAlert && !lastTiltAlert) {
    Serial.printf("[MPU] TILT ALERT roll=%.1f pitch=%.1f (limit=%.0f)\n",
                  imu.roll, imu.pitch, TILT_ALERT_DEG);
  }
  if (!imu.tiltAlert && lastTiltAlert) {
    Serial.printf("[MPU] TILT OK roll=%.1f pitch=%.1f\n", imu.roll, imu.pitch);
  }
  lastImpact = imu.impact;
  lastTiltAlert = imu.tiltAlert;
}

void logSensors(uint32_t nowMs) {
  if (nowMs - lastSensorLogMs < LOG_SENSOR_MS) return;
  lastSensorLogMs = nowMs;

  Serial.println(F("---------- SENSOR STATUS ----------"));
  Serial.printf("[RAIN] muc_nuoc=%.1f%% adc=%u ema=%.0f flag=%s\n",
                rain.percent, rain.adcRaw, rain.adcEma,
                rain.flag ? "CO_NUOC" : "KHO");
  Serial.printf("[SOIL] do_am=%.1f%% adc=%u ema=%.0f flag=%s\n",
                soil.percent, soil.adcRaw, soil.adcEma,
                soil.flag ? "DAT_KHO" : "DAT_AM");

  if (imu.ready) {
#if LOG_VERBOSE
    Serial.printf("[MPU] roll=%.2f pitch=%.2f | a(g)=%.3f,%.3f,%.3f |g|=%.3f\n",
                  imu.roll, imu.pitch, imu.ax, imu.ay, imu.az, imu.accelMag);
    Serial.printf("[MPU] gyro(dps)=%.2f,%.2f,%.2f impact=%d tilt=%d\n",
                  imu.gx, imu.gy, imu.gz, imu.impact ? 1 : 0, imu.tiltAlert ? 1 : 0);
#else
    Serial.printf("[MPU] roll=%.1f pitch=%.1f |a|=%.2fg impact=%d tilt=%d\n",
                  imu.roll, imu.pitch, imu.accelMag,
                  imu.impact ? 1 : 0, imu.tiltAlert ? 1 : 0);
#endif
  } else {
    Serial.println(F("[MPU] not ready"));
  }

  Serial.printf("[WARN] wetRisk=%d satLo=%d | W=%.0f%% S=%.0f%% tilt=%.1f shake=%.2f\n",
                wetRiskAlert ? 1 : 0, landslideAlert ? 1 : 0,
                rain.percent, soil.percent,
                fmaxf(fabsf(imu.roll), fabsf(imu.pitch)),
                fabsf(imu.accelMag - 1.0f));

  Serial.printf("[LORA] ready=%d ver=0x%02X attempts=%lu txOk=%lu txFail=%lu seq=%lu\n",
                loraReady ? 1 : 0,
                lastLoraVersion,
                (unsigned long)loraInitAttempts,
                (unsigned long)txOkCount,
                (unsigned long)txFailCount,
                (unsigned long)packetSeq);
  if (!loraReady) {
    Serial.printf("[LORA][DBG] NSS=%d RST=%d DIO0=%d (expect chip ver=0x12)\n",
                  digitalRead(LORA_NSS), digitalRead(LORA_RST), digitalRead(LORA_DIO0));
  }
  Serial.println(F("-----------------------------------"));
}

void buzzerInit() {
  pinMode(PIN_BUZZER, OUTPUT);
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcAttach(PIN_BUZZER, BUZZER_FREQ_HZ, 8);
  ledcWrite(PIN_BUZZER, 0);
#else
  ledcSetup(BUZZER_CH, BUZZER_FREQ_HZ, 8);
  ledcAttachPin(PIN_BUZZER, BUZZER_CH);
  ledcWrite(BUZZER_CH, 0);
#endif
  Serial.printf("[BUZZER] PWM init pin=%d freq=%dHz (passive/active)\n",
                PIN_BUZZER, BUZZER_FREQ_HZ);
}

void buzzOff() {
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWriteTone(PIN_BUZZER, 0);
  ledcWrite(PIN_BUZZER, 0);
#else
  ledcWriteTone(BUZZER_CH, 0);
  ledcWrite(BUZZER_CH, 0);
#endif
  digitalWrite(PIN_BUZZER, LOW);  // ép LOW — giảm “tích” nhiễu RF lúc LoRa TX
  buzzUntilMs = 0;
}

void buzzOn(uint32_t durationMs) {
  // PWM ~2.7kHz: còi thụ động cần tần số; còi chủ động cũng thường kêu được
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWriteTone(PIN_BUZZER, BUZZER_FREQ_HZ);
#else
  ledcWriteTone(BUZZER_CH, BUZZER_FREQ_HZ);
  ledcWrite(BUZZER_CH, BUZZER_DUTY);
#endif
  buzzUntilMs = millis() + durationMs;
  Serial.printf("[BUZZER] ON %lums @ %dHz\n",
                (unsigned long)durationMs, BUZZER_FREQ_HZ);
}

void buzzerSelfTest() {
  // 1 tiếng ngắn lúc boot — tránh ù ù như self-test x3
  Serial.println(F("[BUZZER] self-test 1x"));
  buzzOn(120);
  delay(140);
  buzzOff();
  Serial.println(F("[BUZZER] self-test done"));
}

void updateLandslide(uint32_t nowMs) {
  float tiltAbs = fmaxf(fabsf(imu.roll), fabsf(imu.pitch));
  float shakeG  = fabsf(imu.accelMag - 1.0f);

  bool waterHigh  = rain.percent >= LANDSLIDE_WATER_PCT;
  bool soilWet    = soil.percent >= LANDSLIDE_SOIL_PCT;
  bool wetNow     = waterHigh && soilWet;

  bool tiltRisk   = imu.ready && (tiltAbs >= LANDSLIDE_TILT_DEG);
  bool shakeRisk  = imu.ready && (imu.impact || shakeG >= LANDSLIDE_SHAKE_G);
  bool motionRisk = tiltRisk || shakeRisk;
  bool slideNow   = wetNow && motionRisk;

  // Mức 1: nước + ẩm cao
  if (wetNow) {
    if (wetRiskCondSinceMs == 0) wetRiskCondSinceMs = nowMs;
    if (nowMs - wetRiskCondSinceMs >= WET_RISK_HOLD_MS) wetRiskAlert = true;
  } else {
    wetRiskCondSinceMs = 0;
    wetRiskAlert = false;
  }

  // Mức 2: + rung/nghiêng
  if (slideNow) {
    if (landslideCondSinceMs == 0) landslideCondSinceMs = nowMs;
    if (nowMs - landslideCondSinceMs >= LANDSLIDE_HOLD_MS) landslideAlert = true;
  } else {
    landslideCondSinceMs = 0;
    landslideAlert = false;
  }

  if (wetRiskAlert && !lastWetRiskAlert) {
    Serial.printf("[WET_RISK] ON water=%.1f%% soil=%.1f%% (coi canh bao)\n",
                  rain.percent, soil.percent);
  }
  if (!wetRiskAlert && lastWetRiskAlert) {
    Serial.println(F("[WET_RISK] OFF"));
  }
  if (landslideAlert && !lastLandslideAlert) {
    Serial.printf("[SAT_LO] ALERT ON water=%.1f%% soil=%.1f%% tiltAbs=%.1f shakeG=%.2f\n",
                  rain.percent, soil.percent, tiltAbs, shakeG);
  }
  if (!landslideAlert && lastLandslideAlert) {
    Serial.println(F("[SAT_LO] ALERT OFF"));
  }
  lastWetRiskAlert = wetRiskAlert;
  lastLandslideAlert = landslideAlert;
}

void updateBuzzer(uint32_t nowMs) {
  if (buzzUntilMs != 0 && nowMs >= buzzUntilMs) {
    buzzOff();
  }

  // Để yên: chỉ còi khi ẩm cao / sạt lở. Rung-nghiêng mặc định im (BUZZER_ON_MOTION=0).
  static bool impactBuzzLatched = false;
  static bool tiltBuzzLatched = false;

  if (landslideAlert) {
    if (nowMs - lastBuzzMs >= (BUZZER_LANDSLIDE_MS + BUZZER_LANDSLIDE_GAP_MS)) {
      buzzOn(BUZZER_LANDSLIDE_MS);
      lastBuzzMs = nowMs;
      Serial.println(F("[SAT_LO] BUZZER ALARM"));
    }
#if BUZZER_ON_MOTION
  } else if (imu.impact) {
    if (!impactBuzzLatched) {
      impactBuzzLatched = true;
      buzzOn(BUZZER_IMPACT_MS);
      lastBuzzMs = nowMs;
    }
  } else if (imu.tiltAlert) {
    if (!tiltBuzzLatched && (nowMs - lastBuzzMs > 1500)) {
      tiltBuzzLatched = true;
      buzzOn(BUZZER_ALERT_MS);
      lastBuzzMs = nowMs;
    }
#endif
  } else if (wetRiskAlert && (nowMs - lastBuzzMs >= BUZZER_WET_GAP_MS)) {
    buzzOn(BUZZER_WET_MS);
    lastBuzzMs = nowMs;
    Serial.println(F("[WET_RISK] BUZZER"));
  }

  if (!imu.impact) impactBuzzLatched = false;
  if (!imu.tiltAlert) tiltBuzzLatched = false;
}

/**
 * Payload CSV:
 * NODE,id,seq,waterPct,soilMoistPct,rainFlag,soilDryFlag,roll,pitch,ax,ay,az,impact,tilt,landslide,wetRisk
 */
void hardResetLoRaChip() {
  Serial.println(F("[LORA][DBG] hard reset SX1278 via RST/NRESET..."));
  pinMode(LORA_RST, OUTPUT);
  digitalWrite(LORA_NSS, HIGH);  // bỏ chọn chip khi reset
  digitalWrite(LORA_RST, HIGH);
  delay(10);
  digitalWrite(LORA_RST, LOW);
  delay(10);
  digitalWrite(LORA_RST, HIGH);
  delay(50);  // SX1278 cần thời gian sau reset
  Serial.printf("[LORA][DBG] after reset RST=%d NSS=%d\n",
                digitalRead(LORA_RST), digitalRead(LORA_NSS));
}

uint8_t readLoRaReg(uint8_t reg) {
  digitalWrite(LORA_NSS, LOW);
  spiLoRa.beginTransaction(SPISettings(LORA_SPI_HZ, MSBFIRST, SPI_MODE0));
  spiLoRa.transfer(reg & 0x7F);
  uint8_t val = spiLoRa.transfer(0x00);
  spiLoRa.endTransaction();
  digitalWrite(LORA_NSS, HIGH);
  return val;
}

void writeLoRaReg(uint8_t reg, uint8_t val) {
  digitalWrite(LORA_NSS, LOW);
  spiLoRa.beginTransaction(SPISettings(LORA_SPI_HZ, MSBFIRST, SPI_MODE0));
  spiLoRa.transfer(reg | 0x80);
  spiLoRa.transfer(val);
  spiLoRa.endTransaction();
  digitalWrite(LORA_NSS, HIGH);
}

void printSx1278WiringHelp() {
  Serial.println(F("[LORA][DBG] === SY SX1278 433MHz wiring (theo TEN chan) ==="));
  Serial.println(F("  Module     ->  ESP32"));
  Serial.println(F("  3.3V/VCC   ->  3V3   (KHONG dung 5V)"));
  Serial.println(F("  GND        ->  GND"));
  Serial.println(F("  NSS / CS   ->  GPIO5"));
  Serial.println(F("  SCK / CLK  ->  GPIO18"));
  Serial.println(F("  MOSI / DI  ->  GPIO23"));
  Serial.println(F("  MISO / DO  ->  GPIO19"));
  Serial.println(F("  RST/NRESET ->  GPIO4"));
  Serial.println(F("  DIO0 / IO0 ->  GPIO25"));
  Serial.println(F("  ANT        ->  anten 433MHz"));
  Serial.println(F("  Hay nham: MISO<->MOSI | MISO<->DIO0 | VCC=5V"));
}

void diagnoseLoRaSpi() {
  Serial.println(F("[LORA][DBG] === SPI probe SX1278 ==="));
  Serial.printf("[LORA][DBG] levels NSS=%d RST=%d DIO0=%d MISO=%d MOSI=%d SCK=%d\n",
                digitalRead(LORA_NSS), digitalRead(LORA_RST),
                digitalRead(LORA_DIO0), digitalRead(LORA_MISO),
                digitalRead(LORA_MOSI), digitalRead(LORA_SCK));

  for (int i = 0; i < 5; i++) {
    uint8_t ver = readLoRaReg(REG_VERSION);
    lastLoraVersion = ver;
    Serial.printf("[LORA][DBG] VERSION[%d]=0x%02X", i, ver);
    if (ver == 0x12) Serial.println(F("  OK SX1278"));
    else if (ver == 0x00 || ver == 0xFF) Serial.println(F("  BAD SPI/wiring/power"));
    else Serial.println(F("  UNEXPECTED"));
    delay(10);
  }

  uint8_t oldSync = readLoRaReg(0x39);
  writeLoRaReg(0x39, 0xA5);
  delay(2);
  uint8_t rd = readLoRaReg(0x39);
  writeLoRaReg(0x39, oldSync);
  Serial.printf("[LORA][DBG] SPI R/W test: wrote 0xA5 read=0x%02X -> %s\n",
                rd, (rd == 0xA5) ? "PASS" : "FAIL");

  if (lastLoraVersion != 0x12) printSx1278WiringHelp();
  Serial.println(F("[LORA][DBG] === end probe ==="));
}

void sendLoRaPacket(const char *reason) {
  if (!loraReady) {
    Serial.printf("[LORA][TX] SKIP - not ready (ver=0x%02X attempts=%lu)\n",
                  lastLoraVersion, (unsigned long)loraInitAttempts);
    return;
  }

  packetSeq++;

  char buf[210];
  int n = snprintf(buf, sizeof(buf),
                   "NODE,%u,%u,%.1f,%.1f,%d,%d,%.2f,%.2f,%.3f,%.3f,%.3f,%d,%d,%d,%d",
                   NODE_ID,
                   packetSeq,
                   rain.percent,
                   soil.percent,
                   rain.flag ? 1 : 0,
                   soil.flag ? 1 : 0,
                   imu.roll,
                   imu.pitch,
                   imu.ax,
                   imu.ay,
                   imu.az,
                   imu.impact ? 1 : 0,
                   imu.tiltAlert ? 1 : 0,
                   landslideAlert ? 1 : 0,
                   wetRiskAlert ? 1 : 0);

  if (n < 0) n = 0;
  if (n >= (int)sizeof(buf)) n = (int)sizeof(buf) - 1;

  Serial.printf("[LORA][TX] reason=%s seq=%lu bytes=%d\n",
                reason, (unsigned long)packetSeq, n);
  Serial.printf("[LORA][TX] payload=%s\n", buf);

  uint32_t t0 = millis();
  LoRa.beginPacket();
  LoRa.print(buf);
  bool ok = LoRa.endPacket();  // blocking TX
  uint32_t dt = millis() - t0;

  if (ok) {
    txOkCount++;
    Serial.printf("[LORA][TX] OK airtime~%lums totalOk=%lu\n",
                  (unsigned long)dt, (unsigned long)txOkCount);
  } else {
    txFailCount++;
    Serial.printf("[LORA][TX] FAIL airtime~%lums totalFail=%lu\n",
                  (unsigned long)dt, (unsigned long)txFailCount);
  }
  // LoRa TX 17dBm dễ “tích” còi thụ động gần anten — giữ pin LOW sau TX
  if (buzzUntilMs == 0) buzzOff();
}

bool initLoRa() {
  loraReady = false;
  loraInitAttempts++;

  Serial.println(F("[LORA] ========== INIT SX1278 433MHz =========="));
  Serial.printf("[LORA] attempt #%lu\n", (unsigned long)loraInitAttempts);
  printSx1278WiringHelp();
  Serial.printf("[LORA] code map NSS=%d RST=%d DIO0=%d SCK=%d MISO=%d MOSI=%d\n",
                LORA_NSS, LORA_RST, LORA_DIO0, LORA_SCK, LORA_MISO, LORA_MOSI);

  pinMode(LORA_NSS, OUTPUT);
  digitalWrite(LORA_NSS, HIGH);
  pinMode(LORA_RST, OUTPUT);
  pinMode(LORA_DIO0, INPUT);

  // HSPI riêng + setSPI cho thư viện LoRa
  spiLoRa.begin(LORA_SCK, LORA_MISO, LORA_MOSI, LORA_NSS);
  LoRa.setSPI(spiLoRa);
  LoRa.setSPIFrequency(LORA_SPI_HZ);
  LoRa.setPins(LORA_NSS, LORA_RST, LORA_DIO0);
  Serial.println(F("[LORA][DBG] HSPI + setSPI done"));

  hardResetLoRaChip();
  diagnoseLoRaSpi();

  if (lastLoraVersion != 0x12) {
    Serial.println(F("[LORA] VERSION != 0x12 -> LoRa.begin se fail. FIX WIRING truoc."));
  }

  bool ok = false;
  for (int i = 1; i <= LORA_INIT_RETRIES; i++) {
    hardResetLoRaChip();
    delay(20);
    uint32_t t0 = millis();
    ok = LoRa.begin(433E6);  // cố định 433MHz cho SY SX1278
    uint32_t dt = millis() - t0;
    lastLoraVersion = readLoRaReg(REG_VERSION);
    Serial.printf("[LORA][DBG] begin try %d/%d -> %s (%lums) ver=0x%02X\n",
                  i, LORA_INIT_RETRIES, ok ? "OK" : "FAIL",
                  (unsigned long)dt, lastLoraVersion);
    if (ok) break;
    delay(150);
  }

  if (!ok) {
    Serial.println(F("[LORA] INIT FAIL - chip SX1278 chua giao tiep SPI"));
    Serial.println(F("[LORA] Do freq=433 OK; van de la day/nguon/NSS/MISO"));
    loraReady = false;
    Serial.println(F("[LORA] ========== INIT FAIL =========="));
    return false;
  }

  LoRa.setSpreadingFactor(LORA_SF);
  LoRa.setSignalBandwidth(LORA_BW);
  LoRa.setCodingRate4(LORA_CR);
  LoRa.setTxPower(LORA_TX_POWER_DBM);
  LoRa.enableCrc();
  LoRa.setSyncWord(0x12);

  lastLoraVersion = readLoRaReg(REG_VERSION);
  loraReady = true;
  Serial.printf("[LORA] OK SX1278 ver=0x%02X 433MHz SF=%d Pwr=%ddBm\n",
                lastLoraVersion, LORA_SF, LORA_TX_POWER_DBM);
  Serial.println(F("[LORA] ========== INIT OK =========="));
  return true;
}

bool initMpu() {
  Serial.printf("[MPU] init I2C SDA=%d SCL=%d\n", I2C_SDA, I2C_SCL);
  Wire.begin(I2C_SDA, I2C_SCL);
  if (!mpu.begin(0x68, &Wire)) {
    Serial.println(F("[MPU] not found at 0x68, try 0x69..."));
    if (!mpu.begin(0x69, &Wire)) {
      Serial.println(F("[MPU] init FAILED"));
      return false;
    }
    Serial.println(F("[MPU] found at 0x69"));
  } else {
    Serial.println(F("[MPU] found at 0x68"));
  }

  mpu.setAccelerometerRange(MPU6050_RANGE_4_G);
  mpu.setGyroRange(MPU6050_RANGE_500_DEG);
  mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
  Serial.println(F("[MPU] range=4G gyro=500dps filter=21Hz"));
  delay(50);
  return calibrateMpu();
}

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println(F("\n=== ESP32 LoRa Node ==="));
  Serial.printf("[SYS] NODE_ID=%d sendEvery=%dms logEvery=%dms\n",
                NODE_ID, SEND_INTERVAL_MS, LOG_SENSOR_MS);
  Serial.printf("[SYS] pins rainAO=%d soilAO=%d buzzer=%d\n",
                PIN_RAIN_AO, PIN_SOIL_AO, PIN_BUZZER);

  analogReadResolution(12);          // 0..4095
  analogSetAttenuation(ADC_11db);    // ~0..3.3V
  pinMode(PIN_RAIN_AO, INPUT);
  pinMode(PIN_SOIL_AO, INPUT);
  buzzerInit();
  buzzerSelfTest();  // nếu không nghe: sai dây còi / còi hỏng / nhầm chân

  Serial.printf("[RAIN] boot adc=%d (noi AO GPIO%d)\n", analogRead(PIN_RAIN_AO), PIN_RAIN_AO);
  Serial.printf("[SOIL] boot adc=%d (noi AO GPIO%d)\n", analogRead(PIN_SOIL_AO), PIN_SOIL_AO);
  Serial.println(F("[SYS] Cal ADC: ghi adc khi KHO/UOT roi sua RAIN_ADC_* / SOIL_ADC_*"));

  if (!initLoRa()) {
    for (int i = 0; i < 3; i++) {
      buzzOn(150); delay(180); buzzOff(); delay(120);
    }
  }

  if (!initMpu()) {
    for (int i = 0; i < 5; i++) {
      buzzOn(80); delay(100); buzzOff(); delay(80);
    }
  } else {
    buzzOn(120);
    delay(130);
    buzzOff();
  }

  lastSendMs = millis();
  lastSensorLogMs = millis();
  Serial.println(F("[SYS] setup done - streaming sensor/LoRa logs"));
}

void loop() {
  uint32_t now = millis();

  updateAnalogSensors(now);
  updateMpu(now);
  updateLandslide(now);
  updateBuzzer(now);
  logSensors(now);

  if (now - lastSendMs >= SEND_INTERVAL_MS) {
    lastSendMs = now;
    sendLoRaPacket("periodic");
  }

  // Gửi ngay khi có va đập (không đợi chu kỳ)
  static bool impactLatched = false;
  if (imu.impact && !impactLatched) {
    impactLatched = true;
    sendLoRaPacket("impact");
  }
  if (!imu.impact) impactLatched = false;

  // Gửi ngay khi bắt đầu cảnh báo sạt lở / ẩm cao
  static bool landslideLatched = false;
  static bool wetRiskLatched = false;
  if (landslideAlert && !landslideLatched) {
    landslideLatched = true;
    sendLoRaPacket("landslide");
  }
  if (!landslideAlert) landslideLatched = false;

  if (wetRiskAlert && !wetRiskLatched) {
    wetRiskLatched = true;
    sendLoRaPacket("wet_risk");
  }
  if (!wetRiskAlert) wetRiskLatched = false;
}
