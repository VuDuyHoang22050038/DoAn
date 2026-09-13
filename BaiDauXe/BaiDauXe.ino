#include <Wire.h>
#include <RTClib.h>
#include <LiquidCrystal_I2C.h>
#include <ESP32Servo.h>
#include <EEPROM.h>
#include <WiFi.h>
#include <PubSubClient.h>
#include <WiFiClientSecure.h> 
#include <time.h> 
#include <ArduinoJson.h>

#define EEPROM_SIGNATURE  0xC0DE

// Điều khiển Barrier (Servo) & Cảnh báo (LED RGB)
#define PIN_SERVO     15 // Điều khiển đóng/mở barrier
#define PIN_LED_R     16 // Đỏ: Cổng đóng/Có xe đỗ
#define PIN_LED_G     4  // Xanh: Cổng mở/Còn chỗ
#define PIN_LED_B     2  // Trạng thái hệ thống

#define PIN_BTN_OPEN_AUTO   14  
#define PIN_BTN_OPEN_MANUAL 26  
#define PIN_BTN_CLOSE       13  
#define PIN_RESET_BTN       27 // Đã gán tạm chân 27 (vì chân 27 rảnh do bỏ RFID)

// Cảm biến vật cản hồng ngoại (LM393) tại 4 vị trí đỗ
#define PIN_SLOT1    33
#define PIN_SLOT2    25
#define PIN_SLOT3    32 
#define PIN_SLOT4    34 

#define CLOSE_ANGLE_SERVO 90
#define OPEN_ANGLE_SERVO  0
#define MAX_CARS 4

// CẤU HÌNH WIFI & MQTT
const char* ssid = "IoT";
const char* password = "22052004";
const char* mqtt_server = "e7e61c7128e04eeda4a25b19da01382f.s1.eu.hivemq.cloud";
const int mqtt_port = 8883;
const char* mqtt_user = "Hoang123";
const char* mqtt_pass = "Hoang123";

// ==========================================
// MQTT TOPICS - PHẢI KHỚP CHÍNH XÁC với server.js (Mục 10)
// ==========================================
#define TOPIC_CMD             "parking/command"       // Server -> ESP32: lệnh mở/đóng barrier (tự động)
#define TOPIC_MANUAL          "parking/manual"         // ESP32 <-> Server: mở/đóng thủ công (2 chiều)
#define TOPIC_LCD             "parking/lcd"            // Server -> ESP32: hiển thị tại chỗ (LCD vật lý)
#define TOPIC_SLOTS           "parking/slots"          // ESP32 -> Server: cảm biến chỗ trống (LM393)
#define TOPIC_BARRIER_STATUS  "parking/barrier_status" // ESP32 -> Server: XÁC NHẬN trạng thái vật lý thật của barrier (Mục 9)

// CẤU HÌNH ĐỒNG BỘ GIỜ INTERNET
const char* ntpServer = "pool.ntp.org";
const long  gmtOffset_sec = 7 * 3600; 
const int   daylightOffset_sec = 0;

WiFiClientSecure espClient;
PubSubClient client(espClient);
RTC_DS3231 rtc;
LiquidCrystal_I2C lcd(0x27, 20, 4);
Servo barrierServo;

int parkedCount = 0;
int freeSlotsCount = 4;

// ================== STATE MACHINE ==================
bool barrierOpen = false;           
unsigned long barrierStart = 0;
bool isAutoMode = true;

// Mục 8: ESP32 gửi HEARTBEAT định kỳ báo trạng thái barrier + xác nhận còn đang hoạt động (Online).
// LƯU Ý: Server/App KHÔNG chờ tin này để coi lệnh mở/đóng là thành công - chỉ dùng để
// (1) hiển thị trạng thái kết nối ESP32 Online/Offline, (2) đồng bộ thông tin barrier khi cần.
unsigned long lastHeartbeat = 0;
const unsigned long HEARTBEAT_INTERVAL_MS = 5000; // gửi heartbeat mỗi 5s

unsigned long lastSensor = 0;
unsigned long lastLCD = 0;
unsigned long lastPress = 0;

// ================== CẢM BIẾN LM393 ==================
const unsigned long DEBOUNCE_DELAY = 150;
const unsigned long MQTT_SLOT_THROTTLE = 200; 

struct SlotSensor {
  uint8_t pin;
  bool rawState;
  bool stableState;
  bool publishedState;
  unsigned long debounceTimer;
};

SlotSensor slots[4] = {
  {PIN_SLOT1, false, false, false, 0},
  {PIN_SLOT2, false, false, false, 0},
  {PIN_SLOT3, false, false, false, 0},
  {PIN_SLOT4, false, false, false, 0}
};

unsigned long lastSlotMQTTSent = 0;
bool forceFirstPublish = true; 

// ================== BIỂN SỐ TỪ SERVER ==================
String currentPlate = "";

// ================== EEPROM ==================
struct LogEntry {
  uint32_t uid;
  uint32_t timeIn;
  uint32_t timeOut;
};

struct EEPROMHeader {
  uint16_t sig;
  uint16_t count;
};

const int HEADER_ADDR = 0;
const int LOGS_START = HEADER_ADDR + sizeof(EEPROMHeader);
int eepromAddr = LOGS_START;
const int EEPROM_SIZE_BYTES = 512;

// ================== DISPLAY MESSAGE CHUYÊN NGHIỆP ==================
String displayMessage = "";
String lcdLine[4] = {"", "", "", ""};
unsigned long displayMessageUntil = 0;
unsigned long resetPressStart = 0;
bool resetPending = false;

// Hàm hỗ trợ in chuỗi ra đúng vị trí LCD
void padPrint(int col, int row, const String &s, int width=20) {
  lcd.setCursor(col,row);
  String t = s;
  while ((int)t.length() < width) t += ' ';
  lcd.print(t.substring(0,width));
}

// Hàm đẩy giao diện Pop-up 4 dòng lên màn hình
void setLCDMessage(String l0, String l1, String l2, String l3, unsigned long durationMs) {
  lcdLine[0] = l0;
  lcdLine[1] = l1;
  lcdLine[2] = l2;
  lcdLine[3] = l3;
  displayMessageUntil = millis() + durationMs;
}

// ================== HEARTBEAT / TRẠNG THÁI BARRIER (Mục 8) ==================
// Gửi trạng thái barrier hiện tại lên Server định kỳ (không phải để "xác nhận đã mở/đóng thành công"
// - Server đã coi lệnh là thành công ngay khi gửi - mà chỉ để Server biết ESP32 còn sống/kết nối,
// và có dữ liệu tham khảo thêm về trạng thái vật lý khi cần).
void publishBarrierHeartbeat() {
  String state = barrierOpen ? "open" : "closed";
  String payload = "{\"state\":\"" + state + "\"}";
  client.publish(TOPIC_BARRIER_STATUS, payload.c_str());
}

// Gọi định kỳ trong loop() - không chặn (non-blocking), không ảnh hưởng gì tới việc mở/đóng barrier.
void handleHeartbeat() {
  unsigned long now = millis();
  if (now - lastHeartbeat >= HEARTBEAT_INTERVAL_MS) {
    lastHeartbeat = now;
    publishBarrierHeartbeat();
  }
}

// ================== MQTT RECONNECT ==================
void reconnect() {
  while (!client.connected()) {
    Serial.print("Đang kết nối HiveMQTT...");
    String clientId = "ESP32Check-" + String(random(0xffff), HEX);
    
    if (client.connect(clientId.c_str(), mqtt_user, mqtt_pass)) {
      Serial.println(" ✅ Đã kết nối!");
      client.subscribe(TOPIC_CMD); 
      client.subscribe(TOPIC_MANUAL);  
      client.subscribe(TOPIC_LCD);      
    } else {
      delay(5000);
    }
  }
}

// ================== HELPERS ==================
void showMessage(const char* l1,const char* l2,const char* l3,const char* l4,int d){
  lcd.clear();
  lcd.setCursor(0,0); lcd.print(l1);
  lcd.setCursor(0,1); lcd.print(l2);
  lcd.setCursor(0,2); lcd.print(l3);
  lcd.setCursor(0,3); lcd.print(l4);
  if(d>0) delay(d);
}

void updateLEDStatus() {
  if (barrierOpen) {
    digitalWrite(PIN_LED_R, LOW);
    digitalWrite(PIN_LED_G, HIGH);
    digitalWrite(PIN_LED_B, LOW);
  } 
  else {
    if (freeSlotsCount <= 0 || parkedCount >= MAX_CARS) {
      digitalWrite(PIN_LED_R, HIGH);
      digitalWrite(PIN_LED_G, LOW);
      digitalWrite(PIN_LED_B, LOW);
    } 
    else {
      digitalWrite(PIN_LED_R, LOW);
      digitalWrite(PIN_LED_G, LOW);
      digitalWrite(PIN_LED_B, HIGH);
    }
  }
}

// ================== EEPROM & COUNT ==================
void eepromInit() {
  EEPROM.begin(EEPROM_SIZE_BYTES);
  EEPROMHeader h;
  EEPROM.get(HEADER_ADDR, h);
  if (h.sig != EEPROM_SIGNATURE) {
    h.sig = EEPROM_SIGNATURE;
    h.count = 0;
    EEPROM.put(HEADER_ADDR, h);
    EEPROM.commit();
    eepromAddr = LOGS_START;
  } else {
    eepromAddr = LOGS_START + (int)h.count * sizeof(LogEntry);
    if (eepromAddr < LOGS_START || eepromAddr > EEPROM_SIZE_BYTES) eepromAddr = LOGS_START;
  }
}

void eepromIncrementCount() {
  EEPROMHeader h;
  EEPROM.get(HEADER_ADDR, h);
  if (h.sig != EEPROM_SIGNATURE) {
    h.sig = EEPROM_SIGNATURE;
    h.count = 0;
  }
  h.count++;
  EEPROM.put(HEADER_ADDR, h);
  EEPROM.commit();
}

void saveLog(uint32_t uid, uint32_t timeIn, uint32_t timeOut) {
  if (eepromAddr + (int)sizeof(LogEntry) > EEPROM_SIZE_BYTES) {
    eepromAddr = LOGS_START;
    EEPROMHeader h = {EEPROM_SIGNATURE, 0};
    EEPROM.put(HEADER_ADDR, h);
    EEPROM.commit();
  }

  LogEntry entry = {uid, timeIn, timeOut};
  EEPROM.put(eepromAddr, entry);
  eepromAddr += sizeof(LogEntry);
  EEPROM.commit();
  eepromIncrementCount();
}

// ================== BARRIER CONTROL ==================
void controlBarrierSM() {
  if (barrierOpen && isAutoMode && (millis() - barrierStart >= 5000)) {
      barrierServo.write(CLOSE_ANGLE_SERVO);
      barrierOpen = false;
      Serial.println("Barrier: CLOSED (Auto-close 5s)");
      updateLEDStatus();
      publishBarrierHeartbeat(); // Mục 8: báo ngay trạng thái mới cho Server (không chờ, không chặn)
  }
}

// ================== NÚT NHẤN ==================
void handleButtons() {
  if (millis() - lastPress < 300) return;
  if (digitalRead(PIN_BTN_OPEN_AUTO) == LOW) {
    lastPress = millis();
    client.publish(TOPIC_MANUAL, "{\"action\":\"open\"}");
  }
  else if (digitalRead(PIN_BTN_OPEN_MANUAL) == LOW) {
    lastPress = millis();
    client.publish(TOPIC_MANUAL, "{\"action\":\"open_manual\"}");
  }
  else if (digitalRead(PIN_BTN_CLOSE) == LOW) {
    lastPress = millis();
    client.publish(TOPIC_MANUAL, "{\"action\":\"close\"}");
  }
}

// ================== XỬ LÝ CẢM BIẾN LM393 ==================
void handleSensors(){
  unsigned long now = millis();
  bool needPublish = false;

  for (int i = 0; i < 4; i++) {
    bool currentState = (digitalRead(slots[i].pin) == HIGH);
    if (currentState != slots[i].rawState) {
      slots[i].debounceTimer = now; 
      slots[i].rawState = currentState;
    }

    if ((now - slots[i].debounceTimer) > DEBOUNCE_DELAY) {
      if (slots[i].stableState != slots[i].rawState) {
         slots[i].stableState = slots[i].rawState;
      }
    }

    if (slots[i].stableState != slots[i].publishedState) {
      needPublish = true;
    }
  }

  // Tính số chỗ trống NGAY TẠI CHỖ từ cảm biến (nguồn dữ liệu gốc),
  // không chờ server phản hồi qua "parking/lcd" -> LED/LCD luôn khớp thực tế
  int occupied = 0;
  for (int i = 0; i < 4; i++) {
    if (!slots[i].stableState) occupied++; // stableState=false => có xe (cảm biến bị chắn)
  }
  int newFree = MAX_CARS - occupied;
  if (newFree != freeSlotsCount) {
    freeSlotsCount = newFree;
    updateLEDStatus();
  }

  if ((needPublish || forceFirstPublish) && (now - lastSlotMQTTSent > MQTT_SLOT_THROTTLE)) {
    for (int i=0; i<4; i++) {
      slots[i].publishedState = slots[i].stableState;
    }
    forceFirstPublish = false;
    lastSlotMQTTSent = now;
    String payload = "{\"slot1\":" + String(slots[0].publishedState ? 0 : 1) + 
                     ",\"slot2\":" + String(slots[1].publishedState ? 0 : 1) + 
                     ",\"slot3\":" + String(slots[2].publishedState ? 0 : 1) + 
                     ",\"slot4\":" + String(slots[3].publishedState ? 0 : 1) + "}";
    client.publish(TOPIC_SLOTS, payload.c_str());
    Serial.println("📡 LM393: Đã gửi trạng thái bãi đỗ mới!");
  }
}

// ================== RESET ==================
void handleResetNonBlocking(){
  if (digitalRead(PIN_RESET_BTN) == LOW) {
    if (!resetPending) {
      resetPending = true;
      resetPressStart = millis();
    } else {
      if (millis() - resetPressStart >= 1000) {
        EEPROMHeader h = {EEPROM_SIGNATURE, 0};
        EEPROM.put(HEADER_ADDR, h);
        EEPROM.commit();
        eepromAddr = LOGS_START;
        
        parkedCount = 0;

        client.publish(TOPIC_MANUAL, "{\"action\":\"reset\"}");
        setLCDMessage("   KHOI PHUC GOC    ", " Da xoa toan bo xe  ", "trong bo nho & Server", "", 3000);
        resetPending = false;
      }
    }
  } else {
    resetPending = false;
  }
}

// ================== NHẬN LỆNH TỪ MQTT ==================
void mqttCallback(char* topic, byte* payload, unsigned int length) {
  String message;
  for (unsigned int i = 0; i < length; i++) {
    message += (char)payload[i];
  }

  Serial.print("MQTT message [");
  Serial.print(topic);
  Serial.print("]: ");
  Serial.println(message);

  if (String(topic) == TOPIC_CMD || String(topic) == TOPIC_MANUAL) {
    if (message.indexOf("\"action\":\"open_manual\"") >= 0) {
      barrierServo.write(OPEN_ANGLE_SERVO);
      barrierOpen = true;
      isAutoMode = false;
      updateLEDStatus();
      publishBarrierHeartbeat(); // Mục 8: báo ngay trạng thái mới cho Server (không chờ, không chặn)
    }
    else if (message.indexOf("\"action\":\"open\"") >= 0) {
      barrierServo.write(OPEN_ANGLE_SERVO);
      barrierOpen = true;
      barrierStart = millis();
      isAutoMode = true; 
      updateLEDStatus();
      publishBarrierHeartbeat(); // Mục 8: báo ngay trạng thái mới cho Server (không chờ, không chặn)
    }
    else if (message.indexOf("\"action\":\"close\"") >= 0) {
      barrierServo.write(CLOSE_ANGLE_SERVO);
      barrierOpen = false;
      isAutoMode = false; 
      updateLEDStatus();
      publishBarrierHeartbeat(); // Mục 8: báo ngay trạng thái mới cho Server (không chờ, không chặn)
    }
  }
  
  else if (String(topic) == TOPIC_LCD) {
    int countIndex = message.indexOf("\"count\":");
    if (countIndex >= 0) {
      int valStart = countIndex + 8;
      int valEnd = message.indexOf(",", valStart);
      if (valEnd == -1) valEnd = message.indexOf("}", valStart);
      if (valEnd > valStart) parkedCount = message.substring(valStart, valEnd).toInt(); 
    }

    // Lưu ý: freeSlotsCount KHÔNG lấy từ server nữa, vì đã được tính trực tiếp
    // từ cảm biến LM393 cục bộ trong handleSensors() - tránh 2 nguồn dữ liệu
    // xung đột và tránh LED/LCD bị lệch khi mất kết nối MQTT tạm thời.

    updateLEDStatus();
    
    int plateIndex = message.indexOf("\"plate\":\"");
    if (plateIndex >= 0) {
      int valStart = plateIndex + 9;
      int valEnd = message.indexOf("\"", valStart);
      if (valEnd > valStart) currentPlate = message.substring(valStart, valEnd);
    }

    // Đọc "event": mã sự kiện CỐ ĐỊNH server luôn gửi kèm (không đổi theo câu chữ
    // hiển thị "msg" tiếng Việt) -> tránh bị lệch mỗi khi server đổi lại câu chữ.
    String rawMsg = "";
    int msgIndex = message.indexOf("\"msg\":\"");
    if (msgIndex >= 0) {
      int valStart = msgIndex + 7;
      int valEnd = message.indexOf("\"", valStart);
      if (valEnd > valStart) rawMsg = message.substring(valStart, valEnd);
    }

    String eventName = "";
    int eventIndex = message.indexOf("\"event\":\"");
    if (eventIndex >= 0) {
      int valStart = eventIndex + 9;
      int valEnd = message.indexOf("\"", valStart);
      if (valEnd > valStart) eventName = message.substring(valStart, valEnd);
    }

    if (eventName.length() > 0) {
      if (eventName == "entry_success") {
          setLCDMessage(" XIN CHAO QUY KHACH ", "Bien so xe vao:", "     " + currentPlate, "  Moi xe qua cong!  ", 5000);
          saveLog(0, rtc.now().unixtime(), 0);
      }
      else if (eventName == "exit_wallet" || eventName == "exit_cash_done") {
          setLCDMessage(" TAM BIET QUY KHACH ", "Bien so xe ra:", "     " + currentPlate, " Thuong lo binh an! ", 5000);
          saveLog(0, 0, rtc.now().unixtime());
      }
      else if (eventName == "exit_cash_pending") {
          setLCDMessage("   MOI THU TIEN MAT ", "Bien so xe ra:", "     " + currentPlate, "", 5000);
      }
      else if (eventName == "error_duplicate") {
          setLCDMessage("      CANH BAO      ", "Bien so nay da co", " trong bai!", "", 4000);
      }
      else if (eventName == "error_notfound") {
          setLCDMessage("      CANH BAO      ", "Khong tim thay xe", " trong du lieu bai!", "", 4000);
      }
      else if (eventName == "error_busy") {
          setLCDMessage("      CANH BAO      ", "  Dang xu ly the,   ", "  vui long doi...   ", "", 3000);
      }
      else if (eventName == "full") {
          setLCDMessage("      CANH BAO      ", "   Bai xe da day!   ", " Khong the vao them ", "", 4000);
      }
      else {
          setLCDMessage("     THONG BAO      ", rawMsg, "", "", 4000);
      }
    }
    else if (rawMsg.length() > 0) {
      // Không có "event" (ví dụ bản tin cũ) -> vẫn hiển thị msg thô để không mất thông báo
      setLCDMessage("     THONG BAO      ", rawMsg, "", "", 4000);
    }
  }
}

// ================== LCD DISPLAY GIAO DIỆN MỚI ==================
void updateStatusLCD(){
  if (millis() < displayMessageUntil) {
    padPrint(0, 0, lcdLine[0], 20);
    padPrint(0, 1, lcdLine[1], 20);
    padPrint(0, 2, lcdLine[2], 20);
    padPrint(0, 3, lcdLine[3], 20);
  } 
  else {
    String barrierStr = barrierOpen ? "DANG MO" : "DANG DONG";
    padPrint(0, 0, "Barie: " + barrierStr, 20);
    padPrint(0, 1, "Xe: " + String(parkedCount) + " | Trong: " + String(freeSlotsCount), 20);
    DateTime nowTime = rtc.now();
    char timeBuf[21];
    sprintf(timeBuf, "Ngay: %02d/%02d  %02d:%02d", nowTime.day(), nowTime.month(), nowTime.hour(), nowTime.minute());
    padPrint(0, 2, String(timeBuf), 20);
    padPrint(0, 3, "    VU DUY HOANG    ", 20);
  }
}

// ================== SETUP ==================
void setup() {
  Serial.begin(115200);

  Serial.print("Connecting to WiFi: ");
  Serial.println(ssid);
  WiFi.begin(ssid, password);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("\nWiFi connected!");

  configTime(gmtOffset_sec, daylightOffset_sec, ntpServer);
  Serial.print("Đang lấy giờ từ Internet...");
  while (time(nullptr) < 100000) {
    delay(500);
    Serial.print(".");
  }
  Serial.println(" Xong!");

  espClient.setInsecure();
  client.setServer(mqtt_server, mqtt_port);
  client.setCallback(mqttCallback);
  randomSeed(micros());
  
  reconnect();

  Wire.begin(21,22);

  pinMode(PIN_LED_R,OUTPUT);
  pinMode(PIN_LED_G,OUTPUT);
  pinMode(PIN_LED_B,OUTPUT);

  pinMode(PIN_RESET_BTN,INPUT_PULLUP);
  pinMode(PIN_BTN_OPEN_AUTO,INPUT_PULLUP);
  pinMode(PIN_BTN_OPEN_MANUAL,INPUT_PULLUP);
  pinMode(PIN_BTN_CLOSE,INPUT_PULLUP);

  pinMode(PIN_SLOT1,INPUT);
  pinMode(PIN_SLOT2,INPUT);
  pinMode(PIN_SLOT3,INPUT);
  pinMode(PIN_SLOT4,INPUT);

  lcd.init(); lcd.backlight();
  if (!rtc.begin()) {
    Serial.println("Không tìm thấy RTC");
  } else {
    struct tm timeinfo;
    if (getLocalTime(&timeinfo, 5000)) { 
      rtc.adjust(DateTime(timeinfo.tm_year + 1900, timeinfo.tm_mon + 1, timeinfo.tm_mday, timeinfo.tm_hour, timeinfo.tm_min, timeinfo.tm_sec));
      Serial.println("Đã cập nhật giờ chuẩn Internet vào DS3231!");
    } else {
      Serial.println("Lỗi: Không thể lấy giờ từ Internet, sử dụng giờ cũ của RTC.");
    }
  }

  barrierServo.attach(PIN_SERVO);
  barrierServo.write(CLOSE_ANGLE_SERVO);

  eepromInit();
  showMessage("HE THONG GIU XE", " AI & NFC ANDROID ", "DS3231+LM393", "LCD2004", 1200);
}

// ================== LOOP ==================
void loop(){
  if (!client.connected()) {
    reconnect();
  }
  client.loop(); 

  unsigned long now = millis();

  if (now - lastSensor > 30){ 
    handleSensors();
    lastSensor = now; 
  }

  handleButtons();
  handleResetNonBlocking();
  controlBarrierSM();
  handleHeartbeat(); // Mục 8: gửi heartbeat định kỳ để Server biết ESP32 còn Online (không chặn mở/đóng)
  
  if (now - lastLCD > 400) { 
    updateStatusLCD(); 
    lastLCD = now; 
  }
}