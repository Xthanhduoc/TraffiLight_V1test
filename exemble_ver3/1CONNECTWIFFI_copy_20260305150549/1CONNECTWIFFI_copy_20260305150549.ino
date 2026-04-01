
#include <Wire.h>
#include <WiFiManager.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>

#define SDA_PIN1 21
#define SCL_PIN1 22
#define SDA_PIN2 16
#define SCL_PIN2 17

#define senSorLux 5
#define led 2

TwoWire I2C_1 = Wire;
TwoWire I2C_2 = TwoWire(1);

// ===== WiFi Manager & Network =====
WiFiManager wm;
bool wifiConnected = false;
bool apMode = false;
unsigned long wifiReconnectMillis = 0;
const unsigned long wifiReconnectInterval = 30000;
unsigned long lastWiFiCheck = 0;
const unsigned long wifiCheckInterval = 1000;

// Biến cho blink LED khi kết nối WiFi (non-blocking)
bool wifiConnectBlink = false;
unsigned long wifiConnectBlinkMillis = 0;
int wifiConnectBlinkCount = 0;

// Biến cho blink LED khi kết nối MQTT (non-blocking)
bool mqttConnectBlink = false;
unsigned long mqttConnectBlinkMillis = 0;
int mqttConnectBlinkCount = 0;

// Cấu hình AP cố định
const char* apName = "TrafficLight-AP";
const char* apPassword = NULL;

// ===== MQTT Configuration =====
char mqttServer[40] = "broker.emqx.io";
int mqttPort = 1883;
char mqttTopicSubscribe[40] = "traffic/control";
char mqttTopicPublish[40] = "traffic/status";

// Lưu trữ các parameter để cập nhật sau
WiFiManagerParameter* param_mqtt_server;
WiFiManagerParameter* param_mqtt_port;
WiFiManagerParameter* param_mqtt_topic_sub;
WiFiManagerParameter* param_mqtt_topic_pub;

WiFiClient wifiClient;
PubSubClient mqttClient(wifiClient);

bool mqttConnected = false;
unsigned long mqttReconnectMillis = 0;
const unsigned long mqttReconnectInterval = 5000;
unsigned long lastMqttPublish = 0;
const unsigned long mqttPublishInterval = 3000;
unsigned long lastMqttLoop = 0;
const unsigned long mqttLoopInterval = 10;

String mqttClientIdStr;

// ===== NIGHT MODE =====
bool nightMode = false;           // Trạng thái đèn đang ở chế độ ban đêm
bool nightModeManual = false;     // Chế độ ban đêm thủ công (do người dùng bật)
bool autoMode = false;            // Chế độ tự động (đọc cảm biến)
unsigned long darkStartMillis = 0;
const unsigned long nightDelay = 5000;

// ===== TM1650 ADDRESS =====
#define TM1650_ADDR_SYS   0x24
#define TM1650_ADDR_DIG1  0x34
#define TM1650_ADDR_DIG2  0x35
#define TM1650_ADDR_DIG3  0x36
#define TM1650_ADDR_DIG4  0x37

// ===== LIGHT STATE =====
enum LightState { RED, GREEN, YELLOW };

// ===== TRAFFIC LIGHT STRUCT =====
struct TrafficLight {
  LightState state;
  int counter;
  unsigned long previousMillis;
  bool blinkState;
  unsigned long blinkMillis;
};

TrafficLight light[4];

// ===== TIME CONFIG =====
int redTime = 15;
int greenTime = 10;
int yellowTime = 5;

const unsigned long interval = 1000;
const unsigned long blinkInterval = 500;

// ===== PRIORITY MODE =====
bool priorityMode = false;
int priorityId = -1;

// ===== 7 SEG TABLE =====
const uint8_t segTable[10] = {
  0x3F,0x06,0x5B,0x4F,0x66,
  0x6D,0x7D,0x07,0x7F,0x6F
};

// ===================================================
// ============== HELPER FUNCTIONS ===================
// ===================================================

String getUniqueClientId() {
  uint8_t mac[6];
  WiFi.macAddress(mac);
  char clientId[30];
  snprintf(clientId, 30, "ESP32_Traffic_%02X%02X%02X", mac[3], mac[4], mac[5]);
  return String(clientId);
}

// Callback khi cấu hình được lưu
void saveConfigCallback() {
  Serial.println("Config saved!");
  updateMQTTConfigFromParams();
}

// Cập nhật cấu hình MQTT từ parameters
void updateMQTTConfigFromParams() {
  if (param_mqtt_server) {
    strcpy(mqttServer, param_mqtt_server->getValue());
  }
  if (param_mqtt_port) {
    String portStr = param_mqtt_port->getValue();
    if (portStr.length() > 0) {
      mqttPort = portStr.toInt();
    }
  }
  if (param_mqtt_topic_sub) {
    strcpy(mqttTopicSubscribe, param_mqtt_topic_sub->getValue());
  }
  if (param_mqtt_topic_pub) {
    strcpy(mqttTopicPublish, param_mqtt_topic_pub->getValue());
  }
}

// ===================================================
// ================= WIFI MANAGER ====================
// ===================================================

void setupWiFi() {

  Serial.println("\n--- Initializing WiFi in AP+STA Mode ---");

  wm.setConfigPortalTimeout(180);
  wm.setTitle("Traffic Light Configuration");
  wm.setConnectTimeout(20);
  wm.setConfigPortalBlocking(false);

  wm.setSaveConfigCallback(saveConfigCallback);

  // =========================
  // STYLE giống app mobile
  // =========================
  const char* custom_css = R"rawliteral(
<style>

body{
  font-family:Arial,Helvetica,sans-serif;
  background:linear-gradient(180deg,#9EC7C9,#BFD2D6);
  color:#1e293b;
}

.wrap{
  max-width:420px;
  margin:auto;
}

/* Header */
.header{
  background:linear-gradient(90deg,#2F80ED,#00B4B6);
  padding:14px;
  border-radius:30px;
  text-align:center;
  font-weight:bold;
  color:white;
  font-size:18px;
  box-shadow:0 4px 10px rgba(0,0,0,0.25);
  margin-bottom:20px;
}

/* Card */
.card{
  background:white;
  border-radius:18px;
  padding:20px;
  box-shadow:0 6px 14px rgba(0,0,0,0.2);
  margin-bottom:20px;
}

/* Input */
input{
  border-radius:14px !important;
  border:1px solid #d1d5db !important;
  padding:12px !important;
  font-size:14px !important;
}

/* Select */
select{
  border-radius:14px !important;
  padding:12px !important;
}

/* Button */
button{
  background:#2F80ED !important;
  border:none !important;
  border-radius:30px !important;
  font-size:15px !important;
  padding:12px !important;
  color:white !important;
  font-weight:bold;
}

button:hover{
  background:#1d4ed8 !important;
}

</style>
)rawliteral";

  wm.setCustomHeadElement(custom_css);

  // =========================
  // Header giao diện
  // =========================
  const char* header_html = R"rawliteral(

<div class="header">
🚦 ĐIỀU KHIỂN ĐÈN GIAO THÔNG
</div>

<div class="card">
<p style="text-align:center;color:#64748b">
Cấu hình WiFi và MQTT cho thiết bị ESP32
</p>
</div>

)rawliteral";

  wm.setCustomMenuHTML(header_html);

  // =========================
  // MQTT Parameters
  // =========================
  param_mqtt_server = new WiFiManagerParameter("mqtt_server", "MQTT Server", mqttServer, 40);
  param_mqtt_port = new WiFiManagerParameter("mqtt_port", "MQTT Port", String(mqttPort).c_str(), 6);
  param_mqtt_topic_sub = new WiFiManagerParameter("mqtt_topic_sub", "Subscribe Topic", mqttTopicSubscribe, 40);
  param_mqtt_topic_pub = new WiFiManagerParameter("mqtt_topic_pub", "Publish Topic", mqttTopicPublish, 40);

  wm.addParameter(param_mqtt_server);
  wm.addParameter(param_mqtt_port);
  wm.addParameter(param_mqtt_topic_sub);
  wm.addParameter(param_mqtt_topic_pub);

  // =========================
  // Menu
  // =========================
  std::vector<const char*> menu = {"wifi", "info", "param", "restart"};
  wm.setMenu(menu);
  wm.setShowInfoUpdate(true);

  // =========================
  // Auto connect
  // =========================
  if (!wm.autoConnect(apName, apPassword)) {

    Serial.println("Failed to connect to saved WiFi - Starting AP mode");
    apMode = true;

  } 
  else {

    Serial.println("Connected to saved WiFi");
    apMode = false;
    updateMQTTConfigFromParams();

  }

  wm.startWebPortal();

  Serial.println("WiFi AP: TrafficLight-AP (for configuration and fallback)");
  Serial.println("Connect to this AP to configure WiFi or MQTT settings");
}









void checkWiFiConnection() {
  unsigned long now = millis();
  
  if (now - lastWiFiCheck < wifiCheckInterval) {
    return;
  }
  lastWiFiCheck = now;
  
  wm.process();
  
  bool currentlyConnected = (WiFi.status() == WL_CONNECTED);
  
  if (currentlyConnected) {
    if (!wifiConnected) {
      wifiConnected = true;
      apMode = false;
      
      Serial.println("\n*** WiFi Connected! ***");
      Serial.print("SSID: ");
      Serial.println(WiFi.SSID());
      Serial.print("IP Address: ");
      Serial.println(WiFi.localIP());
      
      updateMQTTConfigFromParams();
      
      Serial.println("MQTT Configuration updated:");
      Serial.print("Server: "); Serial.println(mqttServer);
      Serial.print("Port: "); Serial.println(mqttPort);
      Serial.print("Subscribe: "); Serial.println(mqttTopicSubscribe);
      Serial.print("Publish: "); Serial.println(mqttTopicPublish);
      
      wifiConnectBlink = true;
      wifiConnectBlinkCount = 0;
      wifiConnectBlinkMillis = now;
      
      connectMQTT();
    }
    return;
  }
  
  if (wifiConnected) {
    wifiConnected = false;
    mqttConnected = false;
    Serial.println("*** WiFi Connection Lost! ***");
    Serial.println("AP mode is still active for configuration");
  }
  
  if (now - wifiReconnectMillis >= wifiReconnectInterval) {
    wifiReconnectMillis = now;
    
    if (!apMode) {
      Serial.println("Attempting to reconnect WiFi...");
      WiFi.reconnect();
    }
  }
}

void resetWiFiConfig() {
  Serial.println("Resetting WiFi configuration...");
  wm.resetSettings();
  delay(1000);
  Serial.println("Restarting in AP mode...");
  ESP.restart();
}

// ===================================================
// ================= MQTT FUNCTIONS ==================
// ===================================================

void mqttCallback(char* topic, byte* payload, unsigned int length) {
  Serial.print("MQTT Message received on topic: ");
  Serial.println(topic);
  
  String message = "";
  for (unsigned int i = 0; i < length; i++) {
    message += (char)payload[i];
  }
  
  Serial.print("Command: ");
  Serial.println(message);
  
  parseInput(message);
  
  if (mqttClient.connected()) {
    String response = "ACK: " + message;
    mqttClient.publish(mqttTopicPublish, response.c_str());
  }
}

void connectMQTT() {
  if (!wifiConnected) {
    return;
  }
  
  if (mqttClient.connected()) {
    mqttConnected = true;
    return;
  }
  
  Serial.print("Connecting to MQTT broker...");
  
  mqttClient.setServer(mqttServer, mqttPort);
  mqttClient.setCallback(mqttCallback);
  mqttClient.setKeepAlive(30);
  
  mqttClientIdStr = getUniqueClientId();
  
  if (mqttClient.connect(mqttClientIdStr.c_str())) {
    Serial.println(" connected!");
    Serial.print("Client ID: ");
    Serial.println(mqttClientIdStr);
    
    mqttClient.subscribe(mqttTopicSubscribe);
    
    Serial.print("Subscribed to topic: ");
    Serial.println(mqttTopicSubscribe);
    
    String onlineMsg = "ONLINE|IP:" + WiFi.localIP().toString();
    mqttClient.publish(mqttTopicPublish, onlineMsg.c_str());
    Serial.println("📨 Sent ONLINE message");
    
    mqttConnected = true;
    
    lastMqttPublish = 0;
    
    publishStatus();
    
    mqttConnectBlink = true;
    mqttConnectBlinkCount = 0;
    mqttConnectBlinkMillis = millis();
    
  } else {
    Serial.print(" failed, rc=");
    Serial.print(mqttClient.state());
    Serial.println(" retry later");
    mqttConnected = false;
  }
}

void checkMQTTConnection() {
  if (!wifiConnected) {
    mqttConnected = false;
    return;
  }
  
  unsigned long now = millis();
  
  if (mqttClient.connected()) {
    if (now - lastMqttLoop >= mqttLoopInterval) {
      lastMqttLoop = now;
      mqttClient.loop();
    }
    
    if (now - lastMqttPublish >= mqttPublishInterval) {
      lastMqttPublish = now;
      publishStatus();
    }
    
    mqttConnected = true;
    return;
  }
  
  if (mqttConnected) {
    mqttConnected = false;
    Serial.println("*** MQTT Connection Lost! ***");
    lastMqttPublish = 0;
  }
  
  if (now - mqttReconnectMillis >= mqttReconnectInterval) {
    mqttReconnectMillis = now;
    Serial.println("🔄 Attempting MQTT reconnect...");
    connectMQTT();
  }
}

// Hàm publishStatus đã được sửa theo yêu cầu - chỉ giữ mode, times, lights
void publishStatus() {
  if (!mqttClient.connected()) return;
  
  StaticJsonDocument<512> doc;
  
  // Xác định mode
  if (nightMode) doc["mode"] = "NIGHT";
  else if (priorityMode) doc["mode"] = "PRIORITY";
  else doc["mode"] = "NORMAL";
  
  // Tạo object times
  JsonObject times = doc.createNestedObject("times");
  times["red"] = redTime;
  times["green"] = greenTime;
  times["yellow"] = yellowTime;
  
  // Tạo array lights
  JsonArray lights = doc.createNestedArray("lights");
  for (int i = 0; i < 4; i++) {
    JsonObject lightObj = lights.createNestedObject();
    lightObj["id"] = i;
    switch(light[i].state) {
      case RED: lightObj["state"] = "RED"; break;
      case GREEN: lightObj["state"] = "GREEN"; break;
      case YELLOW: lightObj["state"] = "YELLOW"; break;
    }
    lightObj["counter"] = light[i].counter;
  }
  
  String output;
  serializeJson(doc, output);
  mqttClient.publish(mqttTopicPublish, output.c_str());
  
  Serial.print("📤 Published: ");
  Serial.println(output);
}

// ===================================================
// ================= TM1650 ==========================    
// ===================================================

TwoWire* getBus(int id) {
  if (id < 2) return &I2C_1;
  return &I2C_2;
}

void display00Light(int id) {
  TwoWire* bus = getBus(id);

  if (id % 2 == 0) {
    tm1650_write(*bus, TM1650_ADDR_DIG1, segTable[0]);
    tm1650_write(*bus, TM1650_ADDR_DIG2, segTable[0]);
  } else {
    tm1650_write(*bus, TM1650_ADDR_DIG3, segTable[0]);
    tm1650_write(*bus, TM1650_ADDR_DIG4, segTable[0]);
  }
}

void tm1650_write(TwoWire &bus, uint8_t addr, uint8_t data) {
  bus.beginTransmission(addr);
  bus.write(data);
  bus.endTransmission();
}

void tm1650_init(TwoWire &bus) {
  tm1650_write(bus, TM1650_ADDR_SYS, 0x01);
  tm1650_write(bus, TM1650_ADDR_DIG1, 0x71);
  tm1650_write(bus, TM1650_ADDR_DIG2, 0x71);
  tm1650_write(bus, TM1650_ADDR_DIG3, 0x71);
  tm1650_write(bus, TM1650_ADDR_DIG4, 0x71);
}

void displayNumberOn(TwoWire &bus, uint8_t tens, uint8_t units, int num) {
  if (num < 0) num = 0;

  int t = num / 10;
  int u = num % 10;

  if (num < 10) {
    tm1650_write(bus, tens, 0x00);
    tm1650_write(bus, units, segTable[u]);
  } else {
    tm1650_write(bus, tens, segTable[t]);
    tm1650_write(bus, units, segTable[u]);
  }
}

void displayLight(int id) {
  TwoWire* bus = getBus(id);

  if (id % 2 == 0)
    displayNumberOn(*bus, TM1650_ADDR_DIG1, TM1650_ADDR_DIG2, light[id].counter);
  else
    displayNumberOn(*bus, TM1650_ADDR_DIG3, TM1650_ADDR_DIG4, light[id].counter);
}

void clearLight(int id) {
  TwoWire* bus = getBus(id);

  if (id % 2 == 0) {
    tm1650_write(*bus, TM1650_ADDR_DIG1, 0x00);
    tm1650_write(*bus, TM1650_ADDR_DIG2, 0x00);
  } else {
    tm1650_write(*bus, TM1650_ADDR_DIG3, 0x00);
    tm1650_write(*bus, TM1650_ADDR_DIG4, 0x00);
  }
}

// ===================================================
// ============== NIGHT MODE FUNCTIONS ===============
// ===================================================

void setNightModeManual(bool enable) {
  if (enable) {
    // Bật chế độ thủ công - TẮT chế độ tự động
    if (!nightMode) {
      nightMode = true;
      nightModeManual = true;
      autoMode = false;  // Tắt chế độ tự động
      digitalWrite(led, HIGH); // Bật đèn đường khi vào chế độ ban đêm
      Serial.println("NIGHT MODE MANUAL ON - Auto mode disabled");
      if (mqttClient.connected()) {
        mqttClient.publish(mqttTopicPublish, "STATUS|NIGHT_MODE_MANUAL_ON");
      }
    }
  } else {
    // Tắt chế độ thủ công
    if (nightMode && nightModeManual) {
      nightMode = false;
      nightModeManual = false;
      autoMode = false;  // Tắt luôn chế độ tự động
      darkStartMillis = 0;
      digitalWrite(led, LOW); // Tắt đèn đường khi tắt chế độ ban đêm
      Serial.println("NIGHT MODE MANUAL OFF - Back to normal mode");
      if (mqttClient.connected()) {
        mqttClient.publish(mqttTopicPublish, "STATUS|NIGHT_MODE_MANUAL_OFF");
      }
      initSystem();
    }
  }
}

// Hàm kiểm tra chế độ ban đêm tự động - CHỈ chạy khi autoMode = true
void checkNightMode() {
  // Nếu không ở chế độ tự động thì bỏ qua
  if (!autoMode) {
    return;
  }
  
  // Nếu đang ở chế độ thủ công thì cũng bỏ qua (phòng trường hợp)
  if (nightModeManual) {
    return;
  }
  
  int luxState = digitalRead(senSorLux);
  unsigned long now = millis();

  if (luxState == 1) {
    if (darkStartMillis == 0) {
      darkStartMillis = now;
    }

    if (!nightMode && (now - darkStartMillis >= nightDelay)) {
      nightMode = true;
      digitalWrite(led, HIGH); // Bật đèn đường khi vào chế độ ban đêm tự động
      Serial.println("NIGHT MODE ON (AUTO)");
      if (mqttClient.connected()) {
        mqttClient.publish(mqttTopicPublish, "STATUS|NIGHT_MODE_AUTO_ON");
      }
    }
  } else {
    darkStartMillis = 0;

    if (nightMode && !nightModeManual) {
      nightMode = false;
      digitalWrite(led, LOW); // Tắt đèn đường khi tắt chế độ ban đêm tự động
      Serial.println("NIGHT MODE OFF (AUTO)");
      if (mqttClient.connected()) {
        mqttClient.publish(mqttTopicPublish, "STATUS|NIGHT_MODE_AUTO_OFF");
      }
      initSystem();
    }
  }
}

void handleNightMode() {
  static bool blinkState = false;
  static unsigned long blinkMillis = 0;

  unsigned long now = millis();

  if (now - blinkMillis >= blinkInterval) {
    blinkMillis = now;
    blinkState = !blinkState;

    // LED đã được bật trong checkNightMode hoặc setNightModeManual
    // Không cần điều khiển ở đây nữa

    for (int i = 0; i < 4; i++) {
      if (blinkState)
        display00Light(i);
      else
        clearLight(i);
    }
  }
}

// ===================================================
// ================= PRIORITY ========================
// ===================================================

void handlePriority(int id) {
  if (id == priorityId) {
    light[id].state = GREEN;
    light[id].counter = greenTime;
    displayLight(id);
    return;
  }

  unsigned long now = millis();

  if (now - light[id].blinkMillis >= blinkInterval) {
    light[id].blinkMillis = now;
    light[id].blinkState = !light[id].blinkState;

    if (light[id].blinkState)
      displayLight(id);
    else
      clearLight(id);
  }
}

// ===================================================
// ================= STATE MACHINE ===================
// ===================================================

void updateStateMachine(int id) {
  if (light[id].counter > 0) return;

  switch (light[id].state) {
    case GREEN:
      light[id].state = YELLOW;
      light[id].counter = yellowTime;
      break;

    case YELLOW:
      light[id].state = RED;
      light[id].counter = redTime;
      break;

    case RED:
      light[id].state = GREEN;
      light[id].counter = greenTime;
      break;
  }
}

void updateLight(int id) {
  if (priorityMode) {
    handlePriority(id);
    return;
  }

  unsigned long now = millis();

  if (now - light[id].previousMillis >= interval) {
    light[id].previousMillis = now;
    displayLight(id);
    light[id].counter--;
    updateStateMachine(id);
  }
}

// ===================================================
// ================= INIT SYSTEM =====================
// ===================================================

void initSystem() {
  priorityMode = false;
  priorityId = -1;
  
  // Tắt đèn đường khi khởi tạo lại hệ thống
  digitalWrite(led, LOW);

  light[0].state = GREEN;
  light[2].state = GREEN;

  light[1].state = RED;
  light[3].state = RED;

  for (int i = 0; i < 4; i++) {
    if (light[i].state == GREEN)
      light[i].counter = greenTime;
    else
      light[i].counter = redTime;

    light[i].previousMillis = millis() - interval;
    displayLight(i);
  }
  
  if (mqttClient.connected()) {
    publishStatus();
  }
}

// ===================================================
// ================= SERIAL INPUT ====================
// ===================================================

void parseInput(String input) {
  input.trim();

  if (input == "WIFIRESET") {
    resetWiFiConfig();
    return;
  }
  
  if (input == "WIFISTATUS") {
    Serial.println("=== WiFi Status ===");
    if (WiFi.status() == WL_CONNECTED) {
      Serial.println("WiFi Connected:");
      Serial.print("SSID: ");
      Serial.println(WiFi.SSID());
      Serial.print("IP: ");
      Serial.println(WiFi.localIP());
    } else {
      Serial.println("WiFi Disconnected");
    }
    Serial.print("AP Mode: ");
    Serial.println(apMode ? "ACTIVE (can configure)" : "STANDBY");
    return;
  }

  if (input == "MQTTSTATUS") {
    if (mqttClient.connected()) {
      Serial.println("MQTT Connected:");
      Serial.print("Server: "); Serial.println(mqttServer);
      Serial.print("Subscribe: "); Serial.println(mqttTopicSubscribe);
      Serial.print("Client ID: "); Serial.println(mqttClientIdStr);
    } else {
      Serial.println("MQTT Disconnected");
    }
    return;
  }
  
  if (input == "MQTTRECONNECT") {
    connectMQTT();
    return;
  }

  // ===== NIGHT MODE COMMANDS =====
  if (input == "NM") {
    // Bật chế độ ban đêm thủ công
    if (!nightMode || !nightModeManual) {
      setNightModeManual(true);
    } else {
      Serial.println("Night mode manual already ON");
    }
    return;
  }
  
  if (input == "NMO") {
    // Tắt chế độ ban đêm thủ công - về chế độ bình thường
    Serial.println("NIGHT MODE OFF - SWITCH TO NORMAL MODE");
    
    nightMode = false;
    nightModeManual = false;
    autoMode = false;  // Tắt chế độ tự động
    darkStartMillis = 0;
    
    // Tắt đèn đường ngay lập tức
    digitalWrite(led, LOW);
    
    redTime = 15;
    greenTime = 10;
    yellowTime = 5;
    
    if (mqttClient.connected()) {
      mqttClient.publish(mqttTopicPublish, "STATUS|NIGHT_MODE_MANUAL_OFF");
    }
    
    initSystem();
    return;
  }

  if (input == "NA") {
    // Bật chế độ tự động - đọc cảm biến ánh sáng
    Serial.println("NIGHT MODE AUTO - Sensor reading enabled");
    
    // Tắt chế độ thủ công nếu đang bật
    if (nightModeManual) {
      nightModeManual = false;
    }
    
    // Bật chế độ tự động
    autoMode = true;
    
    // Reset biến đếm
    darkStartMillis = 0;
    
    // Kiểm tra ngay trạng thái cảm biến
    int luxState = digitalRead(senSorLux);
    if (luxState == 1) {
      Serial.println("Sensor detected dark - will check after delay");
    } else {
      Serial.println("Sensor detected light");
      if (nightMode) {
        nightMode = false;
        digitalWrite(led, LOW); // Tắt đèn đường
        initSystem();
      }
    }
    
    if (mqttClient.connected()) {
      mqttClient.publish(mqttTopicPublish, "STATUS|NIGHT_MODE_AUTO_ENABLED");
    }
    return;
  }

  if (input.startsWith("P") && input.length() > 1) {
    int id = input.substring(1).toInt();

    if (id >= 0 && id <= 3) {
      // Khi vào chế độ ưu tiên - tắt tất cả chế độ night
      nightMode = false;
      nightModeManual = false;
      autoMode = false;
      darkStartMillis = 0;
      
      // Tắt đèn đường
      digitalWrite(led, LOW);
      
      priorityMode = true;
      priorityId = id;
      Serial.println("PRIORITY DIRECTION MODE");
      if (mqttClient.connected()) {
        String msg = "STATUS|PRIORITY_" + String(id);
        mqttClient.publish(mqttTopicPublish, msg.c_str());
      }
      
      for (int i = 0; i < 4; i++) {
        if (i == id) {
          light[i].state = GREEN;
          light[i].counter = greenTime;
        } else {
          light[i].state = RED;
          light[i].counter = redTime;
        }
        light[i].previousMillis = millis() - interval;
        displayLight(i);
      }
    }
    return;
  }

  if (input == "P") {
    // Khi vào chế độ đông xe - tắt tất cả chế độ night
    nightMode = false;
    nightModeManual = false;
    autoMode = false;
    darkStartMillis = 0;
    
    // Tắt đèn đường
    digitalWrite(led, LOW);
    
    redTime = 30;
    greenTime = 25;
    yellowTime = 5;
    Serial.println("CHE DO CAO DIEM");
    initSystem();
    return;
  }

  if (input == "L") {
    // Khi vào chế độ ít xe - tắt tất cả chế độ night
    nightMode = false;
    nightModeManual = false;
    autoMode = false;
    darkStartMillis = 0;
    
    // Tắt đèn đường
    digitalWrite(led, LOW);
    
    redTime = 12;
    greenTime = 10;
    yellowTime = 2;
    Serial.println("CHE DO THAP DIEM");
    initSystem();
    return;
  }

  if (input == "N") {
    // Khi vào chế độ bình thường - tắt tất cả chế độ night
    nightMode = false;
    nightModeManual = false;
    autoMode = false;
    darkStartMillis = 0;
    
    // Tắt đèn đường
    digitalWrite(led, LOW);
    
    redTime = 15;
    greenTime = 10;
    yellowTime = 5;
    Serial.println("CHE DO BINH THUONG");
    initSystem();
    return;
  }

  if (input == "E") {
    priorityMode = false;
    priorityId = -1;
    initSystem();
    Serial.println("PRIORITY OFF");
    return;
  }

  int rIndex = input.indexOf('R');
  int gIndex = input.indexOf('G');
  int yIndex = input.indexOf('Y');

  if (rIndex != -1 && gIndex != -1 && yIndex != -1) {
    // Khi vào chế độ tùy chỉnh - tắt tất cả chế độ night
    nightMode = false;
    nightModeManual = false;
    autoMode = false;
    darkStartMillis = 0;
    
    // Tắt đèn đường
    digitalWrite(led, LOW);
    
    int r = input.substring(rIndex + 1, gIndex).toInt();
    int g = input.substring(gIndex + 1, yIndex).toInt();
    int y = input.substring(yIndex + 1).toInt();

    if (r != (g + y)) {
      Serial.println("Red phai = Green + Yellow");
      return;
    }

    redTime = r;
    greenTime = g;
    yellowTime = y;

    Serial.println("CAP NHAT TUY CHINH");
    initSystem();
    return;
  }
  
  Serial.println("Unknown command!");
}

// ===================================================
// ================= SETUP ===========================
// ===================================================

void setup() {
  Serial.begin(115200);
  delay(1000);
  
  Serial.println("\n=================================");
  Serial.println("Traffic Light System Starting...");
  Serial.println("=================================");

  pinMode(senSorLux, INPUT);
  pinMode(led, OUTPUT);
  digitalWrite(led, LOW);

  I2C_1.begin(SDA_PIN1, SCL_PIN1);
  I2C_2.begin(SDA_PIN2, SCL_PIN2);

  tm1650_init(I2C_1);
  tm1650_init(I2C_2);

  initSystem();
  // BẬT CHẾ ĐỘ TỰ ĐỘNG NGAY KHI KHỞI ĐỘNG
  autoMode = true;
  Serial.println("AUTO MODE ENABLED - System will read light sensor");
  
  setupWiFi();
  
  Serial.println("\n*** System Ready ***");
  Serial.println("AP: TrafficLight-AP (always on for configuration)");
  Serial.println("Traffic lights are running independently");
  Serial.println("\nCommands: N, P, L, P0-P3, E, RxxGxxYxx, NM, NMO, NA");
  Serial.println("WiFi: WIFISTATUS, WIFIRESET");
  Serial.println("MQTT: MQTTSTATUS, MQTTRECONNECT");
}

// ===================================================
// ================= LOOP ============================
// ===================================================

void handleBlinks() {
  if (nightMode) return;
  
  unsigned long now = millis();
  
  if (wifiConnectBlink) {
    if (now - wifiConnectBlinkMillis >= 100) {
      wifiConnectBlinkMillis = now;
      if (wifiConnectBlinkCount % 2 == 0) {
        digitalWrite(led, HIGH);
      } else {
        digitalWrite(led, LOW);
      }
      wifiConnectBlinkCount++;
      if (wifiConnectBlinkCount >= 6) {
        wifiConnectBlink = false;
        digitalWrite(led, LOW);
      }
    }
  }
  
  if (mqttConnectBlink) {
    if (now - mqttConnectBlinkMillis >= 100) {
      mqttConnectBlinkMillis = now;
      if (mqttConnectBlinkCount % 2 == 0) {
        digitalWrite(led, HIGH);
      } else {
        digitalWrite(led, LOW);
      }
      mqttConnectBlinkCount++;
      if (mqttConnectBlinkCount >= 10) {
        mqttConnectBlink = false;
        digitalWrite(led, LOW);
      }
    }
  }
}

void loop() {
  if (nightMode) {
    handleNightMode();
  } else {
    for (int i = 0; i < 4; i++) {
      updateLight(i);
    }
  }
  
  handleBlinks();
  
  checkWiFiConnection();

  if (wifiConnected) {
    checkMQTTConnection();
  }

  if (Serial.available()) {
    String input = Serial.readStringUntil('\n');
    input.trim();
    if (input.length() > 0) {
      Serial.print("Received: ");
      Serial.println(input);
      parseInput(input);
    }
  }

  // Chỉ kiểm tra cảm biến khi autoMode = true
  if (autoMode) {
    checkNightMode();
  }
  
  static unsigned long lastBackupPublish = 0;
  unsigned long now = millis();
  if (mqttClient.connected() && (now - lastBackupPublish >= (mqttPublishInterval + 1000))) {
    if (now - lastMqttPublish > (mqttPublishInterval + 500)) {
      lastBackupPublish = now;
      Serial.println("⚠️ Backup publish triggered (slow publish detected)");
      publishStatus();
      lastMqttPublish = now;
    }
  }
  
  delay(10);
}