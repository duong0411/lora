# ESP32 LoRa Node (Ra-02)

Trạm node gửi dữ liệu cảm biến qua LoRa theo sơ đồ đấu của bạn.

## Sơ đồ chân

| Thiết bị | Chân thiết bị | ESP32 | Ghi chú |
|---|---|---|---|
| LoRa Ra-02 | VCC/GND | 3V3/GND | Chỉ 3.3V |
| LoRa Ra-02 | NSS | GPIO5 | SPI CS |
| LoRa Ra-02 | SCK | GPIO18 | SPI Clock |
| LoRa Ra-02 | MISO | GPIO19 | SPI MISO |
| LoRa Ra-02 | MOSI | GPIO23 | SPI MOSI |
| LoRa Ra-02 | RST | GPIO4 | Reset |
| LoRa Ra-02 | DIO0 | GPIO25 | IRQ |
| Cảm biến mưa | **AO** | GPIO32 | Mực nước / mức mưa (%) |
| Cảm biến đất | **AO** | GPIO33 | Độ ẩm đất (%) |
| Buzzer | + | GPIO13 | - nối GND |
| MPU6050 | VCC/GND | 3V3/GND | Không dùng 5V |
| MPU6050 | SCL/SDA | GPIO22 / GPIO21 | I2C |

## Thư viện Arduino IDE

Cài qua Library Manager:

1. **LoRa** by Sandeep Mistry
2. **Adafruit MPU6050**
3. **Adafruit Unified Sensor** (dependency)

Board: **ESP32 Dev Module** (hoặc board ESP32 tương ứng).

## Payload LoRa (CSV)

```text
NODE,<id>,<seq>,<waterPct>,<soilMoistPct>,<rainFlag>,<soilDryFlag>,<roll>,<pitch>,<ax>,<ay>,<az>,<impact>,<tilt>
```

Ví dụ:

```text
NODE,1,42,67.5,41.2,1,0,2.15,-1.08,0.012,-0.005,0.998,0,0
```

- `waterPct`: mực nước / mức mưa 0..100%
- `soilMoistPct`: độ ẩm đất 0..100%
- `rainFlag=1`: có nước (sau hysteresis)
- `soilDryFlag=1`: đất khô
- `impact=1`: va đập/rung mạnh
- `tilt=1`: nghiêng vượt ngưỡng

## Thuật toán cải thiện độ chính xác

### Mưa & đất (AO)
- Đọc ADC nhiều mẫu → **median**
- **EMA** làm mượt
- Map 2 điểm khô/ướt → **%**
- **Hysteresis** chống dao động cờ trạng thái

### MPU6050
- **Hiệu chuẩn offset** khi khởi động (giữ yên thiết bị)
- **EMA** làm mượt accel/gyro
- **Complementary filter** kết hợp gyro + accel → `roll`/`pitch` ổn định hơn
- **Impact detection**: `|a| - 1g` vượt ngưỡng
- **Tilt alert**: nghiêng > 35°

## Tuỳ chỉnh nhanh (trong `.ino`)

- `LORA_FREQ_HZ`: `433E6` (Ra-02 phổ biến). Đổi nếu module 868/915.
- `RAIN_ADC_DRY` / `RAIN_ADC_WET`, `SOIL_ADC_DRY` / `SOIL_ADC_WET`: hiệu chuẩn theo module thật.
- `SEND_INTERVAL_MS`: chu kỳ gửi (mặc định 3 giây).
- `IMPACT_THRESHOLD_G`, `TILT_ALERT_DEG`: độ nhạy cảnh báo.

## Lưu ý phần cứng

- Ra-02 và MPU6050 đều dùng **3.3V**.
- Anten LoRa phải gắn trước khi TX.
- Cảm biến mưa/đất: nối **AO → GPIO32/33** (không dùng DO nếu cần %).
