// LiDAR Focus – 1. lépés: szervó teszt soros porton keresztül
// Board: WEMOS LOLIN32 Lite, szervó: MG90 a GPIO5-ön
//
// Használat (Serial Monitor, 115200 baud, "Newline" sorvég):
//   1500   -> a szervó 1500 µs impulzusra áll (közép)
//   1000   -> egyik irány, 2000 -> másik irány
// A tartomány biztonsági okból 500..2500 µs közé van korlátozva.

const int SERVO_PIN = 5;
const int PWM_FREQ = 50;          // 50 Hz = 20 ms periódus (szabványos szervó)
const int PWM_BITS = 16;          // felbontás: 20000 µs / 65536 ≈ 0,3 µs lépés
const int PULSE_MIN = 500;
const int PULSE_MAX = 2500;

int currentUs = 1500;

void setPulse(int us) {
  us = constrain(us, PULSE_MIN, PULSE_MAX);
  currentUs = us;
  uint32_t duty = (uint32_t)((uint64_t)us * ((1UL << PWM_BITS) - 1) / 20000UL);
  ledcWrite(SERVO_PIN, duty);
}

void setup() {
  Serial.begin(115200);
  delay(300);
  ledcAttach(SERVO_PIN, PWM_FREQ, PWM_BITS);
  setPulse(1500);
  Serial.println();
  Serial.println("LiDAR Focus - 1. lepes: szervo teszt");
  Serial.println("Irj be egy erteket 500..2500 kozott (us), pl. 1500");
}

void loop() {
  if (Serial.available()) {
    String line = Serial.readStringUntil('\n');
    line.trim();
    if (line.length() == 0) return;
    int v = line.toInt();
    if (v == 0 && line != "0") {
      Serial.println("Nem szam: " + line);
      return;
    }
    setPulse(v);
    Serial.printf("Szervo -> %d us\n", currentUs);
  }
}
