# ESP32 LoRa Gateway (nhận)

Nhận dữ liệu từ `lora_esp32_node`, hiện OLED + còi cảnh báo.

## Đường dẫn

`C:\Users\Duong Phung\Downloads\viloence\violence-detection\lora_esp32_gateway\lora_esp32_gateway.ino`

## Phần cứng

| Thiết bị | Chân | ESP32 |
|---|---|---|
| LoRa SX1278 | VCC/GND | 3V3 / GND |
| LoRa | NSS | GPIO5 |
| LoRa | RST | GPIO4 |
| LoRa | DIO0 | GPIO25 |
| LoRa | SCK | GPIO18 |
| LoRa | MISO | GPIO19 |
| LoRa | MOSI | GPIO23 |
| OLED 0.96" | SDA | GPIO21 |
| OLED 0.96" | SCL | GPIO22 |
| OLED | VCC/GND | 3V3 / GND |
| Còi | + | GPIO13 |
| Còi | - | GND |

## Thư viện Arduino

1. LoRa (Sandeep Mistry)
2. Adafruit SSD1306
3. Adafruit GFX

## Còi khi nào

- Sạt lở (`landslide=1`): dài, lặp
- Va đập (`impact=1`)
- Ẩm/nước cao (`wetRisk=1`)
- Nghiêng (`tilt=1`)
