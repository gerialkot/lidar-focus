// LiDAR Focus – 2. lépés: szervó vezérlés Bluetooth (BLE) + soros porton, simítással
// Board: WEMOS LOLIN32 Lite, szervó: MG90 a GPIO5-ön
//
// BLE eszköz neve: "LiDARFocus"
//   Service UUID:  d4d460b4-0917-44c6-bcb5-1bedf9ba1fe6
//   Target  (írható):     02fe3441-a588-4c2b-9e64-6b85d560343c
//       - szövegként:  "1500"  (pl. nRF Connect -> UTF-8 / Text)
//       - binárisan:   2 bájt, uint16 little-endian µs (ezt fogja küldeni az iPhone app)
//   Status  (olvasható/notify): 287a7ff3-83c5-48d6-95cf-2c4747a0e1b8
//       - szöveg, pl. "cel=1500 most=1500"
//
// Soros port (115200 baud, Newline): ugyanúgy beírható egy szám, pl. 1500
//
// Simítás: a szervó nem ugrik azonnal a célra, hanem 10 ms-onként
// közelít hozzá (exponenciális simítás + sebességkorlát), így nem rángat.

#include <BLE.h>

#define SERVICE_UUID "d4d460b4-0917-44c6-bcb5-1bedf9ba1fe6"
#define TARGET_UUID  "02fe3441-a588-4c2b-9e64-6b85d560343c"
#define STATUS_UUID  "287a7ff3-83c5-48d6-95cf-2c4747a0e1b8"

const int SERVO_PIN = 5;
const int PWM_FREQ = 50;
const int PWM_BITS = 16;
const int PULSE_MIN = 500;
const int PULSE_MAX = 2500;

// Simítás beállításai
const uint32_t TICK_MS = 10;        // frissítés 100 Hz-en
const float SMOOTH = 0.25f;         // 0..1: mekkora részt tesz meg tickenként a hátralévő útból
const float MAX_STEP_US = 25.0f;    // max. változás tickenként (= 2500 µs/s)

volatile int targetUs = 1500;
float currentUs = 1500.0f;

BLECharacteristic statusChar;
BLECharacteristic targetChar;
bool bleConnected = false;

void writePulse(float us) {
  uint32_t duty = (uint32_t)(us * ((1UL << PWM_BITS) - 1) / 20000.0f);
  ledcWrite(SERVO_PIN, duty);
}

// Szöveges vagy bináris parancs feldolgozása. Visszaadja, sikerült-e.
bool handleCommand(const uint8_t *data, size_t len, const char *source) {
  // Diagnosztika: a beérkező nyers bájtok kiírása (hex + szöveg)
  Serial.printf("[%s] nyers %u bajt:", source, (unsigned)len);
  for (size_t i = 0; i < len; i++) Serial.printf(" %02X", data[i]);
  Serial.print("  '");
  for (size_t i = 0; i < len; i++) Serial.print(isprint(data[i]) ? (char)data[i] : '.');
  Serial.println("'");

  if (len == 0) return false;
  bool allDigits = true;
  for (size_t i = 0; i < len; i++) {
    char c = (char)data[i];
    if (!(isdigit(c) || c == '\r' || c == '\n' || c == ' ')) { allDigits = false; break; }
  }
  int v;
  if (allDigits) {
    char tmp[12];
    size_t n = len < sizeof(tmp) - 1 ? len : sizeof(tmp) - 1;
    memcpy(tmp, data, n);
    tmp[n] = 0;
    v = atoi(tmp);
  } else if (len == 2) {
    v = data[0] | (data[1] << 8);
  } else {
    Serial.printf("[%s] ismeretlen parancs (%u bajt)\n", source, (unsigned)len);
    return false;
  }
  if (v <= 0) return false;
  targetUs = constrain(v, PULSE_MIN, PULSE_MAX);
  Serial.printf("[%s] cel -> %d us\n", source, targetUs);
  return true;
}

void setupBle() {
  BTStatus st = BLE.begin("LiDARFocus");
  if (!st) { Serial.printf("[BLE] inditas HIBA: %s\n", st.toString()); return; }
  BLEServer server = BLE.createServer();
  server.onConnect([](BLEServer, const BLEConnInfo &) {
    bleConnected = true;
    Serial.println("[BLE] kapcsolodott");
  });
  server.onDisconnect([](BLEServer, const BLEConnInfo &, uint8_t) {
    bleConnected = false;
    Serial.println("[BLE] lecsatlakozott, ujra hirdetes...");
    BLE.startAdvertising();
  });

  BLEService svc = server.createService(BLEUUID(SERVICE_UUID));
  targetChar = svc.createCharacteristic(BLEUUID(TARGET_UUID),
      BLEProperty::Write | BLEProperty::WriteNR, BLEPermission::WriteOpen);
  targetChar.onWrite([](BLECharacteristic c, const BLEConnInfo &) {
    size_t len = 0;
    const uint8_t *data = c.getValue(&len);
    handleCommand(data, len, "BLE");
  });

  statusChar = svc.createCharacteristic(BLEUUID(STATUS_UUID),
      BLEProperty::Read | BLEProperty::Notify, BLEPermission::ReadOpen);
  statusChar.setValue(String("cel=1500 most=1500"));

  st = server.start();
  if (!st) { Serial.printf("[BLE] szerver HIBA: %s\n", st.toString()); return; }
  BLEAdvertising adv = BLE.getAdvertising();
  adv.addServiceUUID(BLEUUID(SERVICE_UUID));
  st = adv.start();
  if (!st) { Serial.printf("[BLE] hirdetes HIBA: %s\n", st.toString()); return; }
  Serial.println("[BLE] OK, hirdetes fut");
}

void setup() {
  Serial.begin(115200);
  delay(300);
  ledcAttach(SERVO_PIN, PWM_FREQ, PWM_BITS);
  writePulse(currentUs);
  setupBle();
  Serial.println();
  Serial.println("LiDAR Focus - 2. lepes: BLE + simitas");
  Serial.println("BLE nev: LiDARFocus. Soros porton is irhatsz erteket (500..2500).");
}

void loop() {
  // Soros parancs
  if (Serial.available()) {
    String line = Serial.readStringUntil('\n');
    line.trim();
    if (line.length()) handleCommand((const uint8_t *)line.c_str(), line.length(), "Soros");
  }

  // Simított mozgás
  static uint32_t lastTick = 0;
  uint32_t now = millis();
  if (now - lastTick >= TICK_MS) {
    lastTick = now;
    float diff = targetUs - currentUs;
    float step = diff * SMOOTH;
    if (step > MAX_STEP_US) step = MAX_STEP_US;
    if (step < -MAX_STEP_US) step = -MAX_STEP_US;
    if (fabsf(diff) < 0.5f) currentUs = targetUs; else currentUs += step;
    writePulse(currentUs);
  }

  // Állapot küldése 5 Hz-en, ha van kapcsolat
  static uint32_t lastStatus = 0;
  if (bleConnected && statusChar.getSubscribedCount() > 0 && now - lastStatus >= 200) {
    lastStatus = now;
    char buf[40];
    snprintf(buf, sizeof(buf), "cel=%d most=%d", (int)targetUs, (int)lroundf(currentUs));
    statusChar.setValue(String(buf));
    statusChar.notify();
  }
}
