require("dotenv").config();
const express = require("express");
const mqtt = require("mqtt");
const sqlite3 = require("sqlite3").verbose();
const bodyParser = require("body-parser");
const cors = require("cors");
const http = require("http");
const { Server } = require("socket.io");
const bcrypt = require("bcryptjs");

const app = express();
const port = process.env.PORT || 5000;
const server = http.createServer(app);
const io = new Server(server, { cors: { origin: "*" } });

app.use(cors());
app.use(bodyParser.urlencoded({ extended: true }));
app.use(express.json());

// Chuẩn hóa chuỗi: Giữ lại CHỮ VÀ SỐ VIẾT LIỀN
function cleanString(str) {
  if (!str) return "";
  return String(str).replace(/[^a-zA-Z0-9]/g, "").toUpperCase();
}

// Escape HTML chống XSS
function escapeHtml(str) {
  if (str === null || str === undefined) return "";
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

// ==========================================
// CẤU HÌNH BẢO MẬT - BẮT BUỘC LẤY TỪ .env
// (Mục 13: không để credentials mặc định trong source khi chạy thật)
// ==========================================
const REQUIRED_ENV_VARS = ["MQTT_SERVER", "MQTT_USER", "MQTT_PASS", "ADMIN_USER", "ADMIN_PASS"];
const missingEnvVars = REQUIRED_ENV_VARS.filter((k) => !process.env[k]);

if (missingEnvVars.length > 0) {
  console.warn("⚠️  CẢNH BÁO BẢO MẬT: Thiếu biến môi trường trong .env: " + missingEnvVars.join(", "));
  console.warn("⚠️  Đang dùng giá trị DEV mặc định — KHÔNG dùng cấu hình này khi triển khai thực tế.");
  console.warn("⚠️  Hãy tạo file .env (xem .env.example) với MQTT_SERVER, MQTT_USER, MQTT_PASS, ADMIN_USER, ADMIN_PASS.");
}

if (process.env.NODE_ENV === "production" && missingEnvVars.length > 0) {
  console.error("❌ NODE_ENV=production nhưng thiếu biến môi trường bắt buộc. Dừng khởi động server để tránh lộ thông tin mặc định.");
  process.exit(1);
}

// Giá trị DEV mặc định chỉ dùng khi chạy local demo (đồ án). KHÔNG dùng khi triển khai thật.
const MQTT_SERVER = process.env.MQTT_SERVER || "mqtts://e7e61c7128e04eeda4a25b19da01382f.s1.eu.hivemq.cloud:8883";
const MQTT_USER = process.env.MQTT_USER || "Hoang123";
const MQTT_PASS = process.env.MQTT_PASS || "Hoang123";

// Tài khoản Admin từ .env
const ADMIN_USER = process.env.ADMIN_USER || "admin";
const ADMIN_PASS = process.env.ADMIN_PASS || "admin123";

// ==========================================
// MQTT TOPICS
// Mục 10: tách riêng topic cho App (parking/response) và LCD (parking/lcd)
// ==========================================
const TOPIC_ENTRY = "parking/entry";               // App/Kiosk -> Server: xe vào/ra
const TOPIC_CMD = "parking/command";                // Server -> ESP32: lệnh mở/đóng barrier, LED
const TOPIC_LCD = "parking/lcd";                    // Server -> ESP32/LCD: hiển thị tại chỗ
const TOPIC_SLOTS = "parking/slots";                // ESP32 -> Server: cảm biến chỗ trống
const TOPIC_MANUAL = "parking/manual";              // App -> Server: mở/đóng barrier thủ công
const TOPIC_EMPLOYEE_LOGIN = "parking/employee_login"; // App -> Server: đăng nhập tài khoản nhân viên
const TOPIC_SHIFT_END = "parking/shift_end";            // App -> Server: nhân viên kết thúc ca làm việc, lưu lại lịch sử
const TOPIC_SHIFT_HISTORY_REQUEST = "parking/shift_history_request"; // App -> Server: xin xem lại lịch sử ca của chính mình
const TOPIC_EXIT_CONFIRM = "parking/exit_confirm";  // App -> Server: nhân viên xác nhận thu tiền mặt
const TOPIC_RESPONSE = "parking/response";          // Server -> App: kết quả xử lý giao dịch (có requestId)
const TOPIC_BARRIER_STATUS = "parking/barrier_status"; // ESP32 -> Server: xác nhận trạng thái vật lý của barrier
const TOPIC_BARRIER = "parking/barrier";            // Server -> App: phát trạng thái barrier realtime (tách riêng khỏi MQTT/HTTP status)
// Topic MỚI: gộp TOÀN BỘ trạng thái bãi xe + 100 lượt lịch sử gần nhất vào 1 tin nhắn duy nhất,
// publish với retain=true để App nhận NGAY LẬP TỨC dữ liệu mới nhất mỗi khi kết nối/mở app -
// không cần gọi HTTP nữa. Đây là nguồn dữ liệu DUY NHẤT cho App (thay thế /api/history & /api/ping).
const TOPIC_STATE = "parking/state";

// QoS cho các topic quan trọng liên quan tới giao dịch tiền / xe vào-ra (Mục 7)
// >= atLeastOnce (QoS 1) để tránh mất gói tin, kết hợp requestId để chống xử lý trùng
const CRITICAL_TOPIC_QOS = 1;

const MAX_CARS = 4;
// Giá phí KHÔNG còn cố định trong code — được nạp từ bảng `settings` trong DB khi khởi động
// (mỗi bãi xe/mỗi lần triển khai có thể chỉnh giá riêng qua tab "Cài Đặt" trên Dashboard).
// Giá trị dưới đây chỉ là DEFAULT dùng cho lần chạy đầu tiên khi DB chưa có bản ghi settings.
let BASE_FEE = 3000;
let HOURLY_RATE = 2000;

function requireAdminAuth(req, res, next) {
  const authHeader = req.headers.authorization;
  if (authHeader && authHeader.startsWith("Basic ")) {
    const decoded = Buffer.from(authHeader.slice(6), "base64").toString("utf8");
    const sepIndex = decoded.indexOf(":");
    const user = decoded.slice(0, sepIndex);
    const pass = decoded.slice(sepIndex + 1);
    if (user === ADMIN_USER && pass === ADMIN_PASS) return next();
  }
  res.set("WWW-Authenticate", 'Basic realm="Smart Parking Admin"');
  return res.status(401).send("Yêu cầu đăng nhập quản trị.");
}

// Database Init & Schema Updates
const db = new sqlite3.Database("parking.db");

db.serialize(() => {
  db.run("PRAGMA foreign_keys = ON");

  // 1. Bảng lịch sử xe
  db.run(`CREATE TABLE IF NOT EXISTS cars (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      uid TEXT,
      plate TEXT,
      time_in INTEGER,
      time_out INTEGER,
      fee INTEGER,
      payment_method TEXT,
      payment_status TEXT DEFAULT 'PENDING',
      paid_at INTEGER,
      active INTEGER
  )`);

  db.run("ALTER TABLE cars ADD COLUMN payment_status TEXT DEFAULT 'PENDING'", () => {});
  db.run("ALTER TABLE cars ADD COLUMN paid_at INTEGER", () => {});
  db.run(`CREATE INDEX IF NOT EXISTS idx_active ON cars (active)`);

  // 2. Yêu cầu cấp lại mật khẩu
  db.run(`CREATE TABLE IF NOT EXISTS reset_requests (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT,
      status TEXT DEFAULT 'pending'
  )`);

  // 3. Bảng Khách hàng
  db.run(`CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT UNIQUE,
      name TEXT,
      password TEXT,
      balance INTEGER DEFAULT 0
  )`);

  // 4. Biển số xe thuộc tài khoản
  db.run(`CREATE TABLE IF NOT EXISTS plates (
      plate TEXT PRIMARY KEY,
      user_id INTEGER,
      FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
  )`);

  // 5. Bảng ghi log thao tác server
  db.run(`CREATE TABLE IF NOT EXISTS server_logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
      action TEXT,
      details TEXT
  )`);

  // 6. Bảng biến động số dư ví (wallet_transactions)
  db.run(`CREATE TABLE IF NOT EXISTS wallet_transactions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER,
      amount INTEGER,
      type TEXT,
      description TEXT,
      timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
  )`);

  // 7. Bảng chống xử lý trùng giao dịch (Mục 5 & 6: requestId / transactionId)
  // Mỗi giao dịch quan trọng (xe vào, xe ra, thanh toán, mở barrier) đi kèm requestId.
  // Nếu app gửi lại cùng requestId (do mất mạng / retry), server trả lại kết quả CŨ thay vì xử lý lại.
  db.run(`CREATE TABLE IF NOT EXISTS requests (
      request_id TEXT PRIMARY KEY,
      topic TEXT,
      result TEXT,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )`);

  // 8. Bảng cấu hình giá phí — cho phép mỗi bãi xe tự đặt giá riêng thay vì hard-code trong source.
  // Chỉ có đúng 1 dòng cấu hình (id = 1).
  db.run(`CREATE TABLE IF NOT EXISTS settings (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      base_fee INTEGER NOT NULL,
      hourly_rate INTEGER NOT NULL,
      updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )`);

  // Nếu chưa có cấu hình (lần chạy đầu / DB cũ) thì tạo dòng mặc định từ giá trị DEFAULT ở trên.
  db.get("SELECT COUNT(*) AS count FROM settings", (err, row) => {
    if (!err && row && row.count === 0) {
      db.run("INSERT INTO settings (id, base_fee, hourly_rate) VALUES (1, ?, ?)", [BASE_FEE, HOURLY_RATE]);
    }
  });

  // Nạp giá phí hiện tại từ DB vào biến BASE_FEE/HOURLY_RATE đang dùng để tính tiền (calculateFee).
  // Nhờ db.serialize() nên lệnh này luôn chạy SAU khi bảng/dòng mặc định đã được tạo xong ở trên.
  db.get("SELECT base_fee, hourly_rate FROM settings WHERE id = 1", (err, row) => {
    if (!err && row) {
      BASE_FEE = row.base_fee;
      HOURLY_RATE = row.hourly_rate;
      console.log(`💰 Đã nạp cấu hình giá từ DB: Phí giờ đầu = ${BASE_FEE}đ, Phí mỗi giờ tiếp theo = ${HOURLY_RATE}đ`);
    }
  });
  db.run(`CREATE INDEX IF NOT EXISTS idx_requests_created ON requests (created_at)`);

  // 8. Bảng lịch sử ca làm việc của nhân viên - lưu lại mỗi khi App Nhân viên "Kết thúc ca"
  db.run(`CREATE TABLE IF NOT EXISTS shifts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      employee_id TEXT,
      employee_name TEXT,
      start_time INTEGER,
      end_time INTEGER,
      entry_count INTEGER DEFAULT 0,
      exit_count INTEGER DEFAULT 0,
      revenue INTEGER DEFAULT 0,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )`);
  db.run(`CREATE INDEX IF NOT EXISTS idx_shifts_employee ON shifts (employee_id)`);

  // 8. Bảng tài khoản nhân viên bảo vệ (đăng nhập trên App Nhân viên)
  db.run(`CREATE TABLE IF NOT EXISTS employees (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      employee_id TEXT UNIQUE,
      name TEXT,
      password TEXT,
      active INTEGER DEFAULT 1,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )`, () => {
    // Seed 3 tài khoản mặc định NV1/NV2/NV3, mật khẩu mặc định lần lượt là 1/2/3 (chỉ tạo nếu bảng đang trống)
    db.get("SELECT COUNT(*) AS count FROM employees", (err, row) => {
      if (!err && row && row.count === 0) {
        const seed = [
          { employee_id: "NV1", name: "Nhân viên 1", password: "1" },
          { employee_id: "NV2", name: "Nhân viên 2", password: "2" },
          { employee_id: "NV3", name: "Nhân viên 3", password: "3" }
        ];
        seed.forEach((e) => {
          const hashed = bcrypt.hashSync(e.password, 10);
          db.run("INSERT INTO employees (employee_id, name, password, active) VALUES (?,?,?,1)", [e.employee_id, e.name, hashed]);
        });
        console.log("👤 Đã tạo 3 tài khoản nhân viên mặc định: NV1/1, NV2/2, NV3/3 (nên đổi mật khẩu khi triển khai thật)");
      }
    });
  });
});

// Hàm ghi log hệ thống
function writeLog(action, details) {
  const now = new Date().toLocaleString('vi-VN');
  console.log(`[${now}] ${action} - ${details}`);
  db.run("INSERT INTO server_logs (action, details) VALUES (?, ?)", [action, details], (err) => {
    if (err) console.error("Lỗi ghi log DB:", err.message);
  });
}

// Hàm ghi nhật ký ví
function recordWalletTransaction(userId, amount, type, description) {
  db.run("INSERT INTO wallet_transactions (user_id, amount, type, description) VALUES (?, ?, ?, ?)",
    [userId, amount, type, description], (err) => {
      if (err) console.error("Lỗi ghi giao dịch ví:", err.message);
    });
}

// Lock chống race condition (khóa theo biển số trong lúc xử lý 1 request)
const processingPlates = new Set();

// Trạng thái barrier (Mục 8): CLOSED | OPEN — cập nhật ngay khi server gửi lệnh,
// KHÔNG chờ ESP32 phản hồi (theo yêu cầu: nút mở/đóng chỉ cần lý do, không cần ESP32 trả lời).
// Trạng thái kết nối thực tế của ESP32 hiển thị RIÊNG qua isEsp32Online() bên dưới.
let barrierOpen = false;
let barrierState = "CLOSED";

let slot1Occupied = false;
let slot2Occupied = false;
let slot3Occupied = false;
let slot4Occupied = false;
let lastUpdate = Date.now();
let mqttConnected = false;

// Theo dõi ESP32 có thực sự đang hoạt động hay không (KHÔNG hardcode xanh như trước).
// ESP32 coi là Online nếu server nhận được tin nhắn từ nó (cảm biến slot hoặc xác nhận barrier)
// trong vòng ESP32_OFFLINE_TIMEOUT_MS gần nhất. Nếu ESP32 tắt/mất điện, sau thời gian này sẽ tự chuyển Offline.
let lastEsp32Seen = 0;
const ESP32_OFFLINE_TIMEOUT_MS = 20000; // 20s không có tin nào từ ESP32 -> coi là Offline
let _esp32WasOnline = false;
function isEsp32Online() {
  return lastEsp32Seen > 0 && (Date.now() - lastEsp32Seen) < ESP32_OFFLINE_TIMEOUT_MS;
}
// Kiểm tra định kỳ để phát hiện ESP32 vừa RỚT mạng (mất điện/wifi) và cập nhật dashboard kịp thời,
// thay vì phải chờ tới lần notifyWebUpdate() tiếp theo do sự kiện khác gây ra.
setInterval(() => {
  const online = isEsp32Online();
  if (online !== _esp32WasOnline) {
    _esp32WasOnline = online;
    writeLog("ESP32_STATUS", online ? "ESP32 đã kết nối trở lại" : "ESP32 mất kết nối (không nhận được tin nhắn)");
    notifyWebUpdate();
  }
}, 5000);

// ==========================================
// CHỐNG XỬ LÝ TRÙNG GIAO DỊCH THEO requestId (Mục 5 & 6)
// ==========================================

// Dọn bớt các request cũ (>24h) để bảng requests không phình to mãi
setInterval(() => {
  const cutoff = Date.now() - 24 * 60 * 60 * 1000;
  db.run("DELETE FROM requests WHERE created_at < datetime(?, 'unixepoch')", [Math.floor(cutoff / 1000)]);
}, 60 * 60 * 1000);

/**
 * Bọc một thao tác xử lý giao dịch quan trọng bằng cơ chế idempotency.
 * - Nếu requestId đã được xử lý trước đó -> trả lại kết quả CŨ (không xử lý lại, không trừ tiền/ghi xe lần 2).
 * - Nếu chưa -> chạy processFn(finish), processFn phải gọi finish(resultObj) khi xong để lưu + phản hồi.
 * - Nếu không có requestId (client cũ / lệnh không quan trọng) -> xử lý bình thường, không cache.
 */
function withIdempotency(requestId, topic, processFn) {
  if (!requestId) {
    processFn((resultObj) => publishAppResponse(null, resultObj));
    return;
  }

  db.get("SELECT result FROM requests WHERE request_id = ?", [requestId], (err, row) => {
    if (row) {
      // Đã xử lý trước đó (app gửi lại do mất mạng) -> trả kết quả cũ, KHÔNG xử lý lại
      let cached;
      try { cached = JSON.parse(row.result); } catch (e) { cached = { success: false, msg: "Lỗi đọc kết quả cũ" }; }
      writeLog("DEDUP_REQUEST", `requestId=${requestId} đã xử lý trước đó, trả lại kết quả cũ (không tạo giao dịch mới)`);
      publishAppResponse(requestId, cached);
      return;
    }

    processFn((resultObj) => {
      db.run(
        "INSERT OR IGNORE INTO requests (request_id, topic, result) VALUES (?, ?, ?)",
        [requestId, topic, JSON.stringify(resultObj)],
        () => publishAppResponse(requestId, resultObj)
      );
    });
  });
}

// Phản hồi kết quả giao dịch cho App qua topic riêng parking/response (Mục 10),
// tách bạch với parking/lcd (dành cho phần cứng LCD tại chỗ).
function publishAppResponse(requestId, resultObj) {
  const payload = Object.assign({ requestId: requestId || null }, resultObj);
  client.publish(TOPIC_RESPONSE, JSON.stringify(payload), { qos: CRITICAL_TOPIC_QOS });
}

const client = mqtt.connect(MQTT_SERVER, {
  username: MQTT_USER,
  password: MQTT_PASS,
  rejectUnauthorized: false
});

client.on("connect", () => {
  mqttConnected = true;
  console.log("Connected to MQTT broker");
  // Mục 7: QoS >= atLeastOnce cho các topic liên quan giao dịch quan trọng (xe vào/ra, xác nhận thanh toán)
  // Lưu ý: thư viện mqtt.js nhận map {topicName: {qos}} khi cần QoS khác nhau cho từng topic.
  client.subscribe({
    [TOPIC_ENTRY]: { qos: CRITICAL_TOPIC_QOS },
    [TOPIC_EXIT_CONFIRM]: { qos: CRITICAL_TOPIC_QOS },
    [TOPIC_SLOTS]: { qos: 0 },
    [TOPIC_MANUAL]: { qos: CRITICAL_TOPIC_QOS },
    [TOPIC_BARRIER_STATUS]: { qos: CRITICAL_TOPIC_QOS },
    [TOPIC_EMPLOYEE_LOGIN]: { qos: CRITICAL_TOPIC_QOS },
    [TOPIC_SHIFT_END]: { qos: CRITICAL_TOPIC_QOS },
    [TOPIC_SHIFT_HISTORY_REQUEST]: { qos: CRITICAL_TOPIC_QOS }
  });
  writeLog("MQTT_STATUS", "Đã kết nối thành công tới MQTT Broker");
  notifyWebUpdate();
});

client.on("offline", () => { mqttConnected = false; });
client.on("error", () => { mqttConnected = false; });
client.on("reconnect", () => { writeLog("MQTT_STATUS", "Đang thử kết nối lại MQTT Broker..."); });

// Phát trạng thái barrier riêng biệt qua MQTT cho App (Mục 8: tách rõ MQTT/Server API/Barrier)
function broadcastBarrierState() {
  client.publish(TOPIC_BARRIER, JSON.stringify({
    state: barrierState,
    open: barrierOpen
  }), { qos: 0 });
}

function notifyWebUpdate() {
  lastUpdate = Date.now();
  broadcastBarrierState();
  io.emit("reload_data");
  db.get("SELECT COUNT(*) AS count FROM cars WHERE active=1", (err, row) => {
    const parkedCars = row ? row.count : 0;
    const currentFree = getAvailableSlots();
    const sensorOccupied = MAX_CARS - currentFree;
    const isFull = parkedCars >= MAX_CARS || sensorOccupied >= MAX_CARS;

    io.emit("state_update", {
      lastUpdate: lastUpdate,
      parkedCars: parkedCars,
      availableSlots: currentFree,
      maxCars: MAX_CARS,
      slot1: slot1Occupied,
      slot2: slot2Occupied,
      slot3: slot3Occupied,
      slot4: slot4Occupied,
      barrierOpen: barrierOpen,
      barrierState: barrierState,
      isFull: isFull,
      mqttConnected: mqttConnected,
      esp32Online: isEsp32Online()
    });

    // Gộp toàn bộ trạng thái + 100 lượt lịch sử gần nhất, publish qua MQTT (retain=true) cho App.
    // App CHỈ cần 1 kết nối MQTT duy nhất là đủ dữ liệu để hoạt động, không cần HTTP nữa.
    db.all(
      "SELECT id, plate, uid, time_in as entry_time, time_out as exit_time, active, fee, payment_method, payment_status, paid_at FROM cars ORDER BY id DESC LIMIT 100",
      [],
      (err2, rows) => {
        const history = err2 ? [] : rows.map((r) => ({ ...r, status: r.active === 1 ? "IN" : "OUT" }));
        client.publish(
          TOPIC_STATE,
          JSON.stringify({
            parkedCars: parkedCars,
            availableSlots: currentFree,
            maxCars: MAX_CARS,
            slot1: slot1Occupied,
            slot2: slot2Occupied,
            slot3: slot3Occupied,
            slot4: slot4Occupied,
            barrierOpen: barrierOpen,
            barrierState: barrierState,
            isFull: isFull,
            esp32Online: isEsp32Online(),
            history: history
          }),
          { qos: 0, retain: true }
        );
      }
    );
  });
}

function calculateFee(timeInMs, timeOutMs) {
  let durationMs = timeOutMs - timeInMs;
  let hours = Math.ceil(durationMs / (1000 * 60 * 60));
  if (hours <= 1) return BASE_FEE;
  else return BASE_FEE + ((hours - 1) * HOURLY_RATE);
}

function getAvailableSlots() {
  let occupied = 0;
  if (slot1Occupied) occupied++;
  if (slot2Occupied) occupied++;
  if (slot3Occupied) occupied++;
  if (slot4Occupied) occupied++;
  let b = MAX_CARS - occupied;
  return b < 0 ? 0 : b;
}

function checkFullAndNotify() {
  db.get("SELECT COUNT(*) AS count FROM cars WHERE active=1", (err, row) => {
    const dbCount = row ? row.count : 0;
    const sensorOccupied = MAX_CARS - getAvailableSlots();
    const isFull = dbCount >= MAX_CARS || sensorOccupied >= MAX_CARS;

    // Phát tín hiệu đèn đỏ xuống ESP32 nếu bãi đầy
    client.publish(TOPIC_CMD, JSON.stringify({ 
      action: "set_led", 
      color: isFull ? "RED" : "GREEN",
      full: isFull 
    }));
  });
}

// Server/App KHÔNG cần chờ ESP32 phản hồi mới coi là mở/đóng xong — cập nhật trạng thái ngay lập tức
// khi gửi lệnh (giống hành vi gốc). Trạng thái kết nối ESP32 hiển thị RIÊNG BIỆT qua isEsp32Online()
// (dựa trên heartbeat định kỳ từ ESP32), không còn gắn với việc mở/đóng barrier có bị chặn hay không.
function openBarrier(isManual = false) {
  if (isManual) client.publish(TOPIC_CMD, JSON.stringify({ action: "open_manual" }), { qos: CRITICAL_TOPIC_QOS });
  else client.publish(TOPIC_CMD, JSON.stringify({ action: "open" }), { qos: CRITICAL_TOPIC_QOS });

  barrierOpen = true;
  barrierState = "OPEN";
  notifyWebUpdate();

  if (!isManual) {
    setTimeout(() => {
      closeBarrier();
    }, 5000);
  }
}

function closeBarrier() {
  client.publish(TOPIC_CMD, JSON.stringify({ action: "close" }), { qos: CRITICAL_TOPIC_QOS });

  barrierOpen = false;
  barrierState = "CLOSED";
  notifyWebUpdate();
}

function updateLCDJSON(plate, msg, code = 0, fee = 0, event = "generic") {
  db.get("SELECT COUNT(*) AS count FROM cars WHERE active=1", (err, row) => {
    const parkedCars = row ? row.count : 0;
    const free = getAvailableSlots();
    const payload = JSON.stringify({
      count: parkedCars,
      free: free,
      plate: plate || "",
      msg: msg || "",
      code: code,
      fee: fee,
      event: event
    });
    client.publish(TOPIC_LCD, payload);
  });
}

// XỬ LÝ LỆNH TỪ MQTT
client.on("message", (topic, message) => {
  let payload;
  try { payload = JSON.parse(message.toString()); } catch(e) { return; }

  // Đăng nhập tài khoản nhân viên (App Nhân viên gửi lên trước khi vào màn hình chính)
  if (topic === TOPIC_EMPLOYEE_LOGIN) {
    const requestId = payload.requestId || null;
    const empId = cleanString(payload.employee_id);
    const pass = String(payload.password || "");

    if (!empId || !pass) {
      publishAppResponse(requestId, { success: false, event: "employee_login", msg: "Vui lòng nhập đầy đủ tài khoản và mật khẩu" });
      return;
    }

    db.get("SELECT * FROM employees WHERE employee_id = ? COLLATE NOCASE", [empId], (err, emp) => {
      if (err || !emp) {
        publishAppResponse(requestId, { success: false, event: "employee_login", msg: "Tài khoản không tồn tại" });
        return;
      }
      if (emp.active !== 1) {
        publishAppResponse(requestId, { success: false, event: "employee_login", msg: "Tài khoản đã bị khóa" });
        return;
      }
      const ok = bcrypt.compareSync(pass, emp.password);
      if (!ok) {
        publishAppResponse(requestId, { success: false, event: "employee_login", msg: "Sai mật khẩu" });
        return;
      }
      writeLog("EMPLOYEE_LOGIN", `Nhân viên ${emp.employee_id} (${emp.name}) đăng nhập App`);
      publishAppResponse(requestId, {
        success: true,
        event: "employee_login",
        msg: "Đăng nhập thành công",
        employee_id: emp.employee_id,
        name: emp.name
      });
    });
    return;
  }

  // Nhân viên kết thúc ca làm việc - lưu lại lịch sử ca vào bảng shifts để admin/nhân viên kiểm tra sau này
  if (topic === TOPIC_SHIFT_END) {
    const requestId = payload.requestId || null;
    const empId = cleanString(payload.employee_id) || "UNKNOWN";
    const empName = payload.employee_name || empId;
    const startTime = payload.start_time || null;
    const endTime = payload.end_time || Date.now();
    const entryCount = Number(payload.entry_count) || 0;
    const exitCount = Number(payload.exit_count) || 0;
    const revenue = Number(payload.revenue) || 0;

    db.run(
      "INSERT INTO shifts (employee_id, employee_name, start_time, end_time, entry_count, exit_count, revenue) VALUES (?,?,?,?,?,?,?)",
      [empId, empName, startTime, endTime, entryCount, exitCount, revenue],
      function (err) {
        if (err) {
          publishAppResponse(requestId, { success: false, event: "shift_end", msg: "Lỗi lưu lịch sử ca làm việc" });
          return;
        }
        writeLog("SHIFT_END", `Nhân viên ${empId} (${empName}) kết thúc ca: ${entryCount} xe vào, ${exitCount} xe ra, doanh thu ${revenue}đ`);
        publishAppResponse(requestId, { success: true, event: "shift_end", msg: "Đã lưu lịch sử ca làm việc", shift_id: this.lastID });
      }
    );
    return;
  }

  // Nhân viên xin xem lại lịch sử ca làm việc của chính mình (20 ca gần nhất)
  if (topic === TOPIC_SHIFT_HISTORY_REQUEST) {
    const requestId = payload.requestId || null;
    const empId = cleanString(payload.employee_id);
    if (!empId) {
      publishAppResponse(requestId, { success: false, event: "shift_history", msg: "Thiếu mã nhân viên" });
      return;
    }
    db.all(
      "SELECT id, start_time, end_time, entry_count, exit_count, revenue FROM shifts WHERE employee_id = ? ORDER BY id DESC LIMIT 20",
      [empId],
      (err, rows) => {
        if (err) {
          publishAppResponse(requestId, { success: false, event: "shift_history", msg: "Lỗi truy vấn lịch sử ca" });
          return;
        }
        publishAppResponse(requestId, { success: true, event: "shift_history", shifts: rows || [] });
      }
    );
    return;
  }

  // ESP32 gửi heartbeat định kỳ + trạng thái barrier thực tế qua đây (Mục 8).
  // CHỈ mang tính THÔNG TIN — Server/App KHÔNG chờ tin này để coi là mở/đóng thành công
  // (việc mở/đóng đã được xác nhận ngay khi gửi lệnh trong openBarrier()/closeBarrier()).
  // Tác dụng chính: cập nhật lastEsp32Seen để tính trạng thái "ESP32 Online/Offline" chính xác,
  // dùng heartbeat định kỳ thay vì chỉ dựa vào sự kiện cảm biến (vốn có thể im lặng rất lâu nếu không có xe ra/vào).
  if (topic === TOPIC_BARRIER_STATUS) {
    lastEsp32Seen = Date.now();
    const state = String(payload.state || "").toUpperCase();
    const newBarrierOpen = (state === "OPEN" || state === "OPENED");
    const newBarrierState = newBarrierOpen ? "OPEN" : "CLOSED";
    // Chỉ reload dashboard khi trạng thái THỰC SỰ thay đổi, tránh reload liên tục mỗi lần heartbeat
    if (newBarrierState !== barrierState) {
      barrierOpen = newBarrierOpen;
      barrierState = newBarrierState;
      notifyWebUpdate();
    }
    return;
  }

  // XE RA: App Nhân viên gửi xác nhận đã thu tiền mặt
  // Mục 5 & 6: dùng requestId để chống việc app gửi lại (mất mạng/retry) tạo ra 2 lần thu tiền / mở barrier
  if (topic === TOPIC_EXIT_CONFIRM) {
    const cleanPlate = cleanString(payload.plate);
    const reqStatus = payload.payment_status || 'PAID';
    const requestId = payload.requestId || null;
    const tsNow = Date.now();

    if (!cleanPlate) return;

    if (processingPlates.has(cleanPlate)) {
      publishAppResponse(requestId, { success: false, event: "error_busy", msg: "Dang xu ly, vui long doi", plate: cleanPlate });
      return;
    }
    processingPlates.add(cleanPlate);
    const releaseLock = () => processingPlates.delete(cleanPlate);

    withIdempotency(requestId, TOPIC_EXIT_CONFIRM, (finish) => {
      db.get("SELECT * FROM cars WHERE plate = ? AND active = 1 AND payment_status = 'PENDING'", [cleanPlate], (err, car) => {
        if (car && reqStatus === 'PAID') {
          db.run(
            "UPDATE cars SET active = 0, time_out = ?, paid_at = ?, payment_method = 'CASH', payment_status = 'PAID' WHERE id = ?",
            [tsNow, tsNow, car.id],
            function(err) {
              releaseLock();
              if (!err && this.changes > 0) {
                writeLog("PAYMENT_CASH_SUCCESS", `Thu tiền mặt xe ${cleanPlate} - Phí: ${car.fee || 0}đ (requestId=${requestId || "-"})`);
                openBarrier(false);
                updateLCDJSON(cleanPlate, "DA THU TIEN MAT", 1, car.fee || 0, "exit_cash_done");
                notifyWebUpdate();
                checkFullAndNotify();
                finish({ success: true, event: "exit_cash_done", msg: "DA THU TIEN MAT", plate: cleanPlate, fee: car.fee || 0 });
              } else {
                finish({ success: false, event: "error_update", msg: "Loi cap nhat CSDL", plate: cleanPlate });
              }
            }
          );
        } else {
          releaseLock();
          finish({ success: false, event: "error_notfound", msg: "Khong tim thay xe dang cho thu tien", plate: cleanPlate });
        }
      });
    });
  }

  // MỞ/ĐÓNG BARRIER THỦ CÔNG TỪ APP (Mục 3: đồng bộ field "employee" thay vì "user")
  if (topic === TOPIC_MANUAL) {
    const reason = payload.reason || "Mở thủ công từ thiết bị";
    const emp = payload.employee || "SYSTEM";
    const requestId = payload.requestId || null;

    if (payload.action === "open_manual" || payload.action === "open") {
      // Sửa lỗi: TRƯỚC ĐÂY luôn gọi openBarrier(true) (thủ công) bất kể action là gì,
      // khiến "open" (tự động 5s) KHÔNG BAO GIỜ được server lên lịch tự đóng thật sự -
      // trong khi App chỉ đếm 5s ảo trên UI rồi báo "đã đóng" dù cổng vẫn mở thật.
      const isManual = payload.action === "open_manual";
      writeLog("MANUAL_BARRIER_OPEN", `Nhân viên/Thiết bị: ${emp} | Lý do: ${reason} | Chế độ: ${isManual ? "GIỮ CỔNG" : "TỰ ĐỘNG 5S"}`);
      openBarrier(isManual);
      publishAppResponse(requestId, { success: true, event: "manual_open", msg: "Da gui lenh mo barrier khan cap" });
    } else if (payload.action === "close") {
      writeLog("MANUAL_BARRIER_CLOSE", `Đóng barrier thủ công bởi ${emp}`);
      closeBarrier();
      publishAppResponse(requestId, { success: true, event: "manual_close", msg: "Da gui lenh dong barrier" });
    }
  }

  if (topic === TOPIC_SLOTS) {
    lastEsp32Seen = Date.now();
    slot1Occupied = (payload.slot1 == 1 || payload.slot1 == true);
    slot2Occupied = (payload.slot2 == 1 || payload.slot2 == true);
    slot3Occupied = (payload.slot3 == 1 || payload.slot3 == true);
    slot4Occupied = (payload.slot4 == 1 || payload.slot4 == true);
    notifyWebUpdate();
    checkFullAndNotify();
  }

  if (topic === TOPIC_ENTRY) {
    const cleanUid = cleanString(payload.uid);
    const cleanPlate = cleanString(payload.plate);
    const type = payload.type;
    const requestId = payload.requestId || null;
    const tsNow = Date.now();

    if (!cleanUid || !cleanPlate) return;

    if (processingPlates.has(cleanPlate)) {
      updateLCDJSON(cleanPlate, "ERR: Dang xu ly, vui long doi", 0, 0, "error_busy");
      publishAppResponse(requestId, { success: false, event: "error_busy", msg: "Dang xu ly, vui long doi", plate: cleanPlate });
      return;
    }
    processingPlates.add(cleanPlate);
    const releaseLock = () => processingPlates.delete(cleanPlate);

    if (type === "out") {
      // XE RA: XỬ LÝ TÍNH PHÍ VÀ TRỪ VÍ TỰ ĐỘNG
      withIdempotency(requestId, TOPIC_ENTRY, (finish) => {
        db.get("SELECT * FROM cars WHERE uid = ? AND plate = ? AND active = 1", [cleanUid, cleanPlate], (err, exactMatch) => {
          if (exactMatch) {
            const fee = calculateFee(exactMatch.time_in, tsNow);
            db.get("SELECT u.id, u.balance FROM users u JOIN plates p ON u.id = p.user_id WHERE p.plate = ?", [cleanPlate], (err, user) => {
              if (user && user.balance >= fee) {
                  // Ví đủ tiền -> WALLET + PAID
                  db.run("UPDATE users SET balance = balance - ? WHERE id = ?", [fee, user.id]);
                  recordWalletTransaction(user.id, -fee, 'PARKING_FEE', `Thanh toán phí gửi xe biển số ${cleanPlate}`);

                  db.run("UPDATE cars SET time_out = ?, paid_at = ?, fee = ?, active = 0, payment_method = 'WALLET', payment_status = 'PAID' WHERE id = ?", 
                    [tsNow, tsNow, fee, exactMatch.id], (err) => {
                      releaseLock();
                      if (!err) {
                        writeLog("PAYMENT_WALLET_SUCCESS", `Trừ ví tự động xe ${cleanPlate} (${fee}đ) (requestId=${requestId || "-"})`);
                        openBarrier(false);
                        updateLCDJSON(cleanPlate, "THANH TOAN: VI", 1, fee, "exit_wallet");
                        notifyWebUpdate();
                        checkFullAndNotify();
                        finish({ success: true, event: "exit_wallet", msg: "THANH TOAN: VI", plate: cleanPlate, fee: fee });
                      } else {
                        finish({ success: false, event: "error_update", msg: "Loi cap nhat CSDL", plate: cleanPlate });
                      }
                    });
              } else {
                  // Ví thiếu tiền hoặc khách vãng lai -> CASH + PENDING
                  db.run("UPDATE cars SET fee = ?, payment_method = 'CASH', payment_status = 'PENDING' WHERE id = ?", [fee, exactMatch.id], (err) => {
                    releaseLock();
                    if (!err) {
                      writeLog("PAYMENT_PENDING_CASH", `Xe ${cleanPlate} chờ thu tiền mặt (${fee}đ)`);
                      updateLCDJSON(cleanPlate, "THU TIEN MAT", 2, fee, "exit_cash_pending");
                      notifyWebUpdate();
                      finish({ success: true, event: "exit_cash_pending", msg: "THU TIEN MAT", plate: cleanPlate, fee: fee });
                    } else {
                      finish({ success: false, event: "error_update", msg: "Loi cap nhat CSDL", plate: cleanPlate });
                    }
                  });
              }
            });
          } else {
             releaseLock();
             updateLCDJSON(cleanPlate, "ERR: Khong tim thay xe", 0, 0, "error_notfound");
             finish({ success: false, event: "error_notfound", msg: "Khong tim thay xe", plate: cleanPlate });
          }
        });
      });
    } else if (type === "in") {
      // XE VÀO: KIỂM TRA ĐIỀU KIỆN FULL VÀ ĐẦU VÀO
      withIdempotency(requestId, TOPIC_ENTRY, (finish) => {
        db.get("SELECT COUNT(*) AS count FROM cars WHERE active=1", (err, row) => {
          const dbCount = row ? row.count : 0;
          const sensorOccupied = MAX_CARS - getAvailableSlots();
          const isFull = dbCount >= MAX_CARS || sensorOccupied >= MAX_CARS;

          if (isFull) {
            releaseLock();
            writeLog("ENTRY_REJECTED_FULL", `Từ chối xe vào ${cleanPlate} do bãi đã đầy (DB: ${dbCount}, Sensor: ${sensorOccupied})`);
            updateLCDJSON(cleanPlate, "FULL: Bai da day", 0, 0, "full");
            finish({ success: false, event: "full", msg: "Bai da day", plate: cleanPlate });
            return;
          }

          db.get("SELECT * FROM cars WHERE (uid = ? OR plate = ?) AND active = 1", [cleanUid, cleanPlate], (err, existRow) => {
            if (existRow) {
               releaseLock();
               updateLCDJSON(cleanPlate, "ERR: Xe da ton tai", 0, 0, "error_duplicate");
               finish({ success: false, event: "error_duplicate", msg: "Xe da ton tai trong bai", plate: cleanPlate });
            } else {
              db.run("INSERT INTO cars(uid, plate, time_in, active, payment_method, payment_status) VALUES(?,?,?,1,'','PENDING')", [cleanUid, cleanPlate, tsNow], (err) => {
                releaseLock();
                if (!err) {
                  writeLog("CAR_ENTRY_SUCCESS", `Xe vào bãi thành công: ${cleanPlate} (requestId=${requestId || "-"})`);
                  openBarrier(false);
                  updateLCDJSON(cleanPlate, "VAO: THANH CONG", 1, 0, "entry_success");
                  notifyWebUpdate();
                  checkFullAndNotify();
                  finish({ success: true, event: "entry_success", msg: "VAO: THANH CONG", plate: cleanPlate });
                } else {
                  finish({ success: false, event: "error_update", msg: "Loi ghi CSDL", plate: cleanPlate });
                }
              });
            }
          });
        });
      });
    } else {
      releaseLock();
    }
  }
});

// ==========================================
// REST API DÀNH CHO APP NHÂN VIÊN & KHÁCH HÀNG
// ==========================================

// App Nhân viên xác nhận thu tiền mặt
// Mục 5 & 6: hỗ trợ requestId để nếu app gọi lại API này (do timeout/mất mạng) không thu tiền/mở barrier 2 lần
app.post("/api/app/confirm-payment", (req, res) => {
  const { plate, payment_status, employee, requestId } = req.body;
  const cleanPlate = cleanString(plate);
  const tsNow = Date.now();

  if (!cleanPlate || payment_status !== "PAID") {
    return res.status(400).json({ success: false, message: "Dữ liệu xác nhận không hợp lệ" });
  }

  const respondCached = (row) => {
    let cached;
    try { cached = JSON.parse(row.result); } catch (e) { cached = {}; }
    writeLog("DEDUP_REQUEST", `requestId=${requestId} (HTTP confirm-payment) đã xử lý trước đó`);
    return res.json({ success: !!cached.success, message: cached.msg || "Đã xử lý trước đó", data: cached });
  };

  const proceed = () => {
    db.get("SELECT * FROM cars WHERE plate = ? AND active = 1 AND payment_status = 'PENDING'", [cleanPlate], (err, car) => {
      if (!car) {
        const result = { success: false, msg: "Không tìm thấy lượt xe đang chờ thu tiền" };
        if (requestId) db.run("INSERT OR IGNORE INTO requests (request_id, topic, result) VALUES (?,?,?)", [requestId, "http:confirm-payment", JSON.stringify(result)]);
        return res.status(404).json({ success: false, message: result.msg });
      }

      db.run(
        "UPDATE cars SET active = 0, time_out = ?, paid_at = ?, payment_method = 'CASH', payment_status = 'PAID' WHERE id = ?",
        [tsNow, tsNow, car.id],
        function(err2) {
          if (err2) return res.status(500).json({ success: false, message: "Lỗi cập nhật CSDL" });

          writeLog("APP_CASH_CONFIRMED", `Nhân viên ${employee || 'APP'} thu ${car.fee || 0}đ tiền mặt xe ${cleanPlate} (requestId=${requestId || "-"})`);
          openBarrier(false);
          updateLCDJSON(cleanPlate, "DA THU TIEN MAT", 1, car.fee || 0, "exit_cash_done");
          notifyWebUpdate();
          checkFullAndNotify();

          const result = { success: true, msg: "Thanh toán hoàn tất, đang mở barrier", fee: car.fee || 0, plate: cleanPlate };
          if (requestId) db.run("INSERT OR IGNORE INTO requests (request_id, topic, result) VALUES (?,?,?)", [requestId, "http:confirm-payment", JSON.stringify(result)]);
          res.json({ success: true, message: result.msg });
        }
      );
    });
  };

  if (requestId) {
    db.get("SELECT result FROM requests WHERE request_id = ?", [requestId], (err, row) => {
      if (row) return respondCached(row);
      proceed();
    });
  } else {
    proceed();
  }
});

// App Mở Barrier khẩn cấp (Bắt buộc lý do)
app.post("/api/app/manual-open", (req, res) => {
  const { employee, reason } = req.body;
  if (!reason || !reason.trim()) {
    return res.status(400).json({ success: false, message: "Bắt buộc phải nhập lý do mở barrier" });
  }

  const empStr = employee || "NV_APP";
  writeLog("MANUAL_BARRIER_OPEN", `Nhân viên: ${empStr} | Lý do: ${reason}`);
  openBarrier(true);
  res.json({ success: true, message: "Đã gửi lệnh mở barrier khẩn cấp" });
});

// Khách hàng đăng ký (Password Hash)
app.post("/api/customer/register", (req, res) => {
  const { username, name, password } = req.body;
  if (!username || !name || !password) {
    return res.status(400).json({ success: false, message: "Thiếu thông tin đăng ký" });
  }

  const cleanUser = cleanString(username);
  db.get("SELECT id FROM users WHERE username = ?", [cleanUser], (err, row) => {
    if (row) return res.status(409).json({ success: false, message: "Tên đăng nhập đã tồn tại" });

    const hashedPassword = bcrypt.hashSync(password, 10);
    db.run("INSERT INTO users (username, name, password, balance) VALUES (?, ?, ?, 0)", 
      [cleanUser, name, hashedPassword], 
      function (err) {
        if (err) return res.status(500).json({ success: false, message: "Lỗi tạo tài khoản" });
        writeLog("CUSTOMER_REGISTER", `Khách hàng mới tạo tài khoản: ${cleanUser}`);
        notifyWebUpdate();
        res.json({ success: true, data: { id: this.lastID, username: cleanUser, name, balance: 0 } });
      }
    );
  });
});

// Khách hàng Đăng nhập
app.post("/api/customer/login", (req, res) => {
  const identifier = req.body.username || req.body.id;
  const { password } = req.body;

  if (!identifier || !password) return res.status(400).json({ success: false, message: "Thiếu thông tin đăng nhập" });

  const cleanId = cleanString(identifier);
  db.get("SELECT id, username, name, password, balance FROM users WHERE id = ? OR username = ?", [identifier, cleanId], (err, user) => {
    if (err || !user) return res.status(401).json({ success: false, message: "Sai tài khoản hoặc mật khẩu" });

    const isMatch = bcrypt.compareSync(password, user.password) || String(user.password) === String(password);
    if (!isMatch) return res.status(401).json({ success: false, message: "Sai tài khoản hoặc mật khẩu" });

    res.json({
      success: true,
      data: { id: user.id, username: user.username, name: user.name, balance: user.balance }
    });
  });
});

// Xem lịch sử biến động ví
app.get("/api/customer/:id/wallet-transactions", (req, res) => {
  const { id } = req.params;
  const cleanId = cleanString(id);
  db.get("SELECT id FROM users WHERE id = ? OR username = ?", [id, cleanId], (err, user) => {
    if (!user) return res.status(404).json({ success: false, message: "Không tìm thấy tài khoản" });
    db.all("SELECT * FROM wallet_transactions WHERE user_id = ? ORDER BY id DESC LIMIT 100", [user.id], (err2, rows) => {
      res.json({ success: true, data: rows || [] });
    });
  });
});

// Nạp tiền ví
app.post("/api/customer/:id/topup", (req, res) => {
  const { id } = req.params;
  const amount = parseInt(req.body.amount, 10);
  const cleanId = cleanString(id);

  if (isNaN(amount) || amount <= 0) return res.status(400).json({ success: false, message: "Số tiền nạp không hợp lệ" });

  db.get("SELECT id, name FROM users WHERE id = ? OR username = ?", [id, cleanId], (err, user) => {
    if (!user) return res.status(404).json({ success: false, message: "Không tìm thấy tài khoản" });

    db.run("UPDATE users SET balance = balance + ? WHERE id = ?", [amount, user.id], function (err2) {
      if (err2) return res.status(500).json({ success: false, message: "Lỗi cập nhật số dư ví" });

      recordWalletTransaction(user.id, amount, 'TOPUP', 'Nạp tiền vào tài khoản ví');
      writeLog("WALLET_TOPUP", `Nạp ${amount.toLocaleString()}đ vào tài khoản KH #${user.id} (${user.name})`);

      db.get("SELECT balance FROM users WHERE id = ?", [user.id], (err3, row) => {
        notifyWebUpdate();
        res.json({ success: true, data: { balance: row ? row.balance : 0 } });
      });
    });
  });
});

app.get("/api/customer/:id", (req, res) => {
  const { id } = req.params;
  const cleanId = cleanString(id);
  db.get("SELECT id, username, name, balance FROM users WHERE id = ? OR username = ?", [id, cleanId], (err, user) => {
    if (err || !user) return res.status(404).json({ success: false, message: "Không tìm thấy tài khoản" });
    db.all("SELECT plate FROM plates WHERE user_id = ?", [user.id], (err2, plateRows) => {
      res.json({
        success: true,
        data: {
          id: user.id,
          username: user.username,
          name: user.name,
          balance: user.balance,
          plates: (plateRows || []).map(r => r.plate)
        }
      });
    });
  });
});

app.post("/api/customer/:id/plates", (req, res) => {
  const { id } = req.params;
  const cleanPlate = cleanString(req.body.plate);
  const cleanId = cleanString(id);

  if (!cleanPlate) return res.status(400).json({ success: false, message: "Biển số không hợp lệ" });

  db.get("SELECT id FROM users WHERE id = ? OR username = ?", [id, cleanId], (err, user) => {
    if (!user) return res.status(404).json({ success: false, message: "Không tìm thấy tài khoản" });

    db.get("SELECT user_id FROM plates WHERE plate = ?", [cleanPlate], (err2, existing) => {
      if (existing) return res.status(409).json({ success: false, message: "Biển số đã được đăng ký" });
      db.run("INSERT INTO plates (plate, user_id) VALUES (?, ?)", [cleanPlate, user.id], (err3) => {
        if (err3) return res.status(500).json({ success: false, message: "Lỗi thêm biển số" });
        writeLog("ADD_PLATE", `Thêm biển ${cleanPlate} cho KH #${user.id}`);
        notifyWebUpdate();
        res.json({ success: true, data: { plate: cleanPlate } });
      });
    });
  });
});

app.delete("/api/customer/:id/plates/:plate", (req, res) => {
  const { id, plate } = req.params;
  const cleanPlate = cleanString(plate);
  const cleanId = cleanString(id);

  db.get("SELECT id FROM users WHERE id = ? OR username = ?", [id, cleanId], (err, user) => {
    if (!user) return res.status(404).json({ success: false, message: "Không tìm thấy tài khoản" });

    db.run("DELETE FROM plates WHERE plate = ? AND user_id = ?", [cleanPlate, user.id], function (err2) {
      if (err2) return res.status(500).json({ success: false, message: "Lỗi xóa biển số" });
      writeLog("DELETE_PLATE", `Xóa biển số ${cleanPlate} khỏi KH #${user.id}`);
      notifyWebUpdate();
      res.json({ success: true, message: "Đã xóa biển số thành công" });
    });
  });
});

// Lịch sử gửi xe của khách hàng (theo các biển số đã đăng ký của họ) - endpoint này trước đây BỊ THIẾU
// khiến App Khách hàng gọi tới luôn nhận lỗi 404, tab "Lịch sử" không bao giờ tải được dữ liệu.
app.get("/api/customer/:id/history", (req, res) => {
  const { id } = req.params;
  const cleanId = cleanString(id);
  db.get("SELECT id FROM users WHERE id = ? OR username = ?", [id, cleanId], (err, user) => {
    if (err || !user) return res.status(404).json({ success: false, message: "Không tìm thấy tài khoản" });

    db.all(
      `SELECT c.plate, c.uid, c.time_in as entry_time, c.time_out as exit_time, c.active, c.fee, c.payment_method, c.payment_status
       FROM cars c
       WHERE c.plate IN (SELECT plate FROM plates WHERE user_id = ?)
       ORDER BY c.id DESC LIMIT 100`,
      [user.id],
      (err2, rows) => {
        if (err2) return res.status(500).json({ success: false, message: "Lỗi truy vấn lịch sử" });
        res.json({ success: true, data: rows || [] });
      }
    );
  });
});

// Lịch sử biến động số dư ví (nạp tiền / trừ phí gửi xe) - tách riêng khỏi lịch sử gửi xe
app.get("/api/customer/:id/wallet-history", (req, res) => {
  const { id } = req.params;
  const cleanId = cleanString(id);
  db.get("SELECT id FROM users WHERE id = ? OR username = ?", [id, cleanId], (err, user) => {
    if (err || !user) return res.status(404).json({ success: false, message: "Không tìm thấy tài khoản" });

    db.all(
      "SELECT amount, type, description, timestamp FROM wallet_transactions WHERE user_id = ? ORDER BY id DESC LIMIT 100",
      [user.id],
      (err2, rows) => {
        if (err2) return res.status(500).json({ success: false, message: "Lỗi truy vấn lịch sử ví" });
        res.json({ success: true, data: rows || [] });
      }
    );
  });
});

// Endpoint nhẹ để App kiểm tra "HTTP API Online" định kỳ mà không phải tải toàn bộ lịch sử (Mục 1)
app.get("/api/ping", (req, res) => {
  res.json({ success: true, serverTime: Date.now(), mqttConnected: mqttConnected, barrierState: barrierState, esp32Online: isEsp32Online() });
});

// Trạng thái chỗ trống bãi xe - công khai, dùng cho App Khách hàng hiển thị "còn X/4 chỗ" (không cần đăng nhập)
app.get("/api/parking-status", (req, res) => {
  db.get("SELECT COUNT(*) AS count FROM cars WHERE active=1", (err, row) => {
    const parkedCars = row ? row.count : 0;
    const availableSlots = getAvailableSlots();
    res.json({
      success: true,
      parkedCars: parkedCars,
      availableSlots: availableSlots,
      maxCars: MAX_CARS,
      isFull: parkedCars >= MAX_CARS || availableSlots <= 0
    });
  });
});

app.get("/api/history", (req, res) => {
  const sql = "SELECT id, plate, uid, time_in as entry_time, time_out as exit_time, active, fee, payment_method, payment_status, paid_at FROM cars ORDER BY id DESC LIMIT 100";
  db.all(sql, [], (err, rows) => {
      if (err) return res.status(500).json({ success: false, message: 'Lỗi truy vấn DB' });
      res.json({ success: true, data: rows.map(r => ({ ...r, status: r.active === 1 ? 'IN' : 'OUT' })) });
  });
});

// ==========================================
// ROUTE TRANG QUẢN TRỊ ADMIN (WEB INTERFACE)
// ==========================================

// Cho xe ra khẩn cấp (Emergency Checkout) - Bắt buộc nhập lý do
app.post("/force-checkout", requireAdminAuth, (req, res) => {
  const { id, reason } = req.body;
  const tsNow = Date.now();

  if (!reason || !reason.trim()) return res.status(400).send("Lý do xử lý khẩn cấp là bắt buộc.");

  db.get("SELECT * FROM cars WHERE id = ? AND active = 1", [id], (err, row) => {
    if (row) {
      const fee = row.fee || calculateFee(row.time_in, tsNow);
      const cleanPlate = cleanString(row.plate);

      db.run("UPDATE cars SET time_out = ?, paid_at = ?, fee = ?, active = 0, payment_method = 'CASH', payment_status = 'PAID' WHERE id = ?", 
        [tsNow, tsNow, fee, id], (err) => {
          writeLog("ADMIN_EMERGENCY_CHECKOUT", `Admin xử lý khẩn cấp xe ID #${id} (${cleanPlate}) - Lý do: ${reason}`);
          openBarrier(false);
          notifyWebUpdate();
          checkFullAndNotify();
          res.redirect("/");
        });
    } else res.redirect("/");
  });
});

// Mở Barrier thủ công có ghi lý do
app.post("/open-manual", requireAdminAuth, (req, res) => { 
  const reason = req.body.reason || "Admin thao tác mở giữ cổng";
  writeLog("MANUAL_BARRIER_OPEN", `Admin: ${ADMIN_USER} | Lý do: ${reason}`);
  openBarrier(true); 
  res.redirect("/"); 
});

// Xóa 1 lượt đỗ xe (Truy vết ghi log)
app.post("/delete", requireAdminAuth, (req, res) => {
  const { id } = req.body;
  db.run("DELETE FROM cars WHERE id = ?", [id], () => { 
    writeLog("ADMIN_DELETE_HISTORY", `Admin xóa bản ghi lịch sử lượt xe ID #${id}`);
    notifyWebUpdate(); 
    res.redirect("/"); 
  });
});

app.post("/reset-all", requireAdminAuth, (req, res) => { 
  db.run("DELETE FROM cars", () => { 
    writeLog("ADMIN_DELETE_HISTORY", "Admin thực hiện reset xóa toàn bộ lịch sử bãi xe");
    notifyWebUpdate(); 
    res.redirect("/"); 
  }); 
});

app.post("/open-auto", requireAdminAuth, (req, res) => { 
  writeLog("ADMIN_OPEN_AUTO", "Admin bấm mở barrier tự động (5s)");
  openBarrier(false); 
  res.redirect("/"); 
});

app.post("/close", requireAdminAuth, (req, res) => { 
  writeLog("ADMIN_CLOSE_BARRIER", "Admin bấm đóng barrier khẩn cấp");
  closeBarrier(); 
  res.redirect("/"); 
});

// Cập nhật giá phí (Cài Đặt) — mỗi bãi xe có thể có mức giá khác nhau, không còn cố định trong code
app.post("/settings/fee", requireAdminAuth, (req, res) => {
  const baseFee = parseInt(req.body.base_fee, 10);
  const hourlyRate = parseInt(req.body.hourly_rate, 10);

  if (!Number.isInteger(baseFee) || baseFee < 0 || !Number.isInteger(hourlyRate) || hourlyRate < 0) {
    return res.status(400).send("Giá trị không hợp lệ. Phí phải là số nguyên và không được âm.");
  }

  db.run("UPDATE settings SET base_fee = ?, hourly_rate = ?, updated_at = CURRENT_TIMESTAMP WHERE id = 1",
    [baseFee, hourlyRate], (err) => {
      if (err) return res.status(500).send("Lỗi khi lưu cấu hình giá vào DB.");

      const oldBase = BASE_FEE, oldHourly = HOURLY_RATE;
      BASE_FEE = baseFee;
      HOURLY_RATE = hourlyRate;

      writeLog("ADMIN_UPDATE_FEE_SETTINGS",
        `Admin đổi giá: Phí giờ đầu ${oldBase}đ → ${baseFee}đ | Phí mỗi giờ tiếp theo ${oldHourly}đ → ${hourlyRate}đ`);
      notifyWebUpdate();
      res.redirect("/");
    });
});

function generateUniqueId(callback) {
  const randomId = Math.floor(100 + Math.random() * 900);
  db.get("SELECT id FROM users WHERE id = ?", [randomId], (err, row) => {
    if (row) generateUniqueId(callback);
    else callback(randomId);
  });
}

app.post("/users/add", requireAdminAuth, (req, res) => {
    const { name, password, plates, balance } = req.body;
    generateUniqueId((newId) => {
      const usernameStr = "KH" + newId;
      const hashedPassword = bcrypt.hashSync(password, 10);

      db.run("INSERT INTO users (id, username, name, password, balance) VALUES (?, ?, ?, ?, ?)", 
        [newId, usernameStr, name, hashedPassword, parseInt(balance) || 0], 
        function(err) {
          if (!err) {
              const plateArray = (plates || "").split(',').map(p => cleanString(p)).filter(p => p.length > 0);
              plateArray.forEach(cleanPlate => {
                  db.run("INSERT OR IGNORE INTO plates (plate, user_id) VALUES (?, ?)", [cleanPlate, newId]);
              });
              if (parseInt(balance) > 0) {
                recordWalletTransaction(newId, parseInt(balance), 'TOPUP', 'Số dư khởi tạo từ Admin');
              }
              writeLog("ADMIN_ADD_USER", `Tạo KH #${newId} - Username: ${usernameStr} - Tên: ${name}`);
          }
          res.redirect("/");
      });
    });
});

app.post("/users/plates/add", requireAdminAuth, (req, res) => {
  const { user_id, plate } = req.body;
  const cleanPlate = cleanString(plate);
  if (cleanPlate && user_id) {
    db.run("INSERT OR IGNORE INTO plates (plate, user_id) VALUES (?, ?)", [cleanPlate, user_id], () => {
      writeLog("ADMIN_ADD_PLATE", `Thêm biển ${cleanPlate} cho KH #${user_id}`);
      res.redirect("/");
    });
  } else res.redirect("/");
});

app.post("/users/plates/delete", requireAdminAuth, (req, res) => {
  const { plate } = req.body;
  if (plate) {
    db.run("DELETE FROM plates WHERE plate = ?", [plate], () => {
      writeLog("ADMIN_DELETE_PLATE", `Xóa biển số ${plate}`);
      res.redirect("/");
    });
  } else res.redirect("/");
});

app.post("/users/balance", requireAdminAuth, (req, res) => {
    const { id, amount, action } = req.body;
    const value = parseInt(amount) || 0;
    const query = action === 'add' ? "UPDATE users SET balance = balance + ? WHERE id = ?" : "UPDATE users SET balance = balance - ? WHERE id = ?";
    
    db.run(query, [value, id], () => {
      const type = action === 'add' ? 'TOPUP' : 'ADMIN_SUBTRACT';
      const desc = action === 'add' ? 'Admin cộng tiền vào ví' : 'Admin trừ tiền ví';
      recordWalletTransaction(id, action === 'add' ? value : -value, type, desc);

      writeLog("ADMIN_CHANGE_BALANCE", `Admin ${action === 'add' ? 'cộng' : 'trừ'} ${value.toLocaleString()}đ cho KH #${id}`);
      res.redirect("/");
    });
});

app.post("/users/delete", requireAdminAuth, (req, res) => {
    const { id } = req.body;
    db.run("DELETE FROM users WHERE id = ?", [id], () => {
      writeLog("ADMIN_DELETE_USER", `Admin xóa tài khoản Khách hàng #${id}`);
      res.redirect("/");
    });
});

// ==========================================================
// QUẢN LÝ TÀI KHOẢN NHÂN VIÊN (App Nhân viên đăng nhập bằng tài khoản này)
// ==========================================================
app.post("/employees/add", requireAdminAuth, (req, res) => {
  const { employee_id, name, password } = req.body;
  const empId = cleanString(employee_id);
  if (!empId || !password) return res.redirect("/employees");

  const hashed = bcrypt.hashSync(password, 10);
  db.run("INSERT INTO employees (employee_id, name, password, active) VALUES (?, ?, ?, 1)",
    [empId, name || empId, hashed],
    (err) => {
      if (err) writeLog("ADMIN_ADD_EMPLOYEE_FAIL", `Lỗi thêm NV ${empId}: ${err.message}`);
      else writeLog("ADMIN_ADD_EMPLOYEE", `Đã thêm tài khoản nhân viên ${empId} (${name || empId})`);
      res.redirect("/employees");
    });
});

app.post("/employees/reset-password", requireAdminAuth, (req, res) => {
  const { id, password } = req.body;
  if (!id || !password) return res.redirect("/employees");
  const hashed = bcrypt.hashSync(password, 10);
  db.run("UPDATE employees SET password = ? WHERE id = ?", [hashed, id], () => {
    writeLog("ADMIN_RESET_EMPLOYEE_PASSWORD", `Đã đặt lại mật khẩu tài khoản nhân viên #${id}`);
    res.redirect("/employees");
  });
});

app.post("/employees/toggle-active", requireAdminAuth, (req, res) => {
  const { id } = req.body;
  db.run("UPDATE employees SET active = 1 - active WHERE id = ?", [id], () => {
    writeLog("ADMIN_TOGGLE_EMPLOYEE", `Đã đổi trạng thái khóa/mở tài khoản nhân viên #${id}`);
    res.redirect("/employees");
  });
});

app.post("/employees/delete", requireAdminAuth, (req, res) => {
  const { id } = req.body;
  db.run("DELETE FROM employees WHERE id = ?", [id], () => {
    writeLog("ADMIN_DELETE_EMPLOYEE", `Đã xóa tài khoản nhân viên #${id}`);
    res.redirect("/employees");
  });
});

// Trang quản lý tài khoản nhân viên (giao diện riêng)
// Hàm dùng chung để render các trang quản trị phụ (Nhân viên, Ca làm việc...) - đồng bộ CHÍNH XÁC
// theme sáng/tối + màu sắc với Dashboard chính và với 2 App (Mục: đồng bộ giao diện toàn hệ thống).
function renderAdminPage(title, activeNav, bodyHtml) {
  return `<!DOCTYPE html>
    <html lang="vi" data-theme="light">
    <head>
      <meta charset="UTF-8">
      <title>${title} - Smart Parking</title>
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@300;400;500;600;700;800&display=swap" rel="stylesheet">
      <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
      <style>
        :root {
          --primary: #0ea5e9; --primary-dark: #0284c7; --primary-light: #e0f2fe;
          --bg-deep: #f0f9ff; --card-bg: #ffffff; --text-bright: #0f172a; --text-dim: #64748b;
          --border: #bae6fd; --shadow: rgba(14, 165, 233, 0.08);
          --success: #10b981; --danger: #ef4444; --warning: #f59e0b;
        }
        [data-theme="dark"] {
          --primary: #38bdf8; --primary-dark: #0284c7; --primary-light: rgba(56, 189, 248, 0.15);
          --bg-deep: #0A192F; --card-bg: #112240; --text-bright: #f8fafc; --text-dim: #94a3b8;
          --border: #233554; --shadow: rgba(0, 0, 0, 0.25);
        }
        * { margin:0; padding:0; box-sizing:border-box; font-family:'Plus Jakarta Sans', sans-serif; transition: background-color .2s, border-color .2s, color .2s; }
        body { background: var(--bg-deep); color: var(--text-bright); min-height:100vh; padding:24px; }
        .wrap { max-width: 1000px; margin:0 auto; }
        .nav { display:flex; align-items:center; justify-content:space-between; background: var(--card-bg); border:1px solid var(--border); border-radius:16px; padding:14px 20px; margin-bottom:22px; box-shadow: 0 10px 25px -5px var(--shadow); }
        .nav-links { display:flex; gap:8px; flex-wrap:wrap; }
        .nav-links a { color: var(--text-dim); text-decoration:none; font-size:13px; font-weight:700; padding:8px 14px; border-radius:10px; }
        .nav-links a.active, .nav-links a:hover { color: #fff; background: var(--primary); }
        .theme-btn { border:1px solid var(--border); background: var(--bg-deep); color: var(--text-bright); border-radius:10px; padding:8px 12px; cursor:pointer; font-size:13px; font-weight:700; }
        h1 { font-size: 20px; margin-bottom:4px; }
        .subtitle { color: var(--text-dim); font-size:13px; margin-bottom:18px; }
        table { width:100%; border-collapse:collapse; background: var(--card-bg); border-radius:14px; overflow:hidden; border:1px solid var(--border); }
        th, td { padding:13px 14px; text-align:left; border-bottom:1px solid var(--border); font-size:13px; }
        th { background: var(--primary-light); font-size:11px; text-transform:uppercase; letter-spacing:.5px; color: var(--text-dim); font-weight:800; }
        tr:last-child td { border-bottom:none; }
        .status-dot { width:8px; height:8px; border-radius:50%; display:inline-block; margin-right:5px; }
        .dot-online { background: var(--success); }
        .dot-offline { background: var(--danger); }
        .control-btn { border:none; border-radius:8px; padding:8px 12px; color:#fff; background: var(--primary); cursor:pointer; font-size:12px; font-weight:700; }
        .btn-close { background: var(--danger); }
        .btn-warn { background: var(--warning); }
        .btn-ok { background: var(--success); }
        .add-box { background: var(--card-bg); border:1px solid var(--border); border-radius:14px; padding:18px; margin-top:22px; }
        .add-box h3 { margin-bottom:12px; font-size:14px; }
        .add-box input { padding:10px; border-radius:8px; border:1px solid var(--border); background: var(--bg-deep); color: var(--text-bright); margin-right:8px; margin-bottom:8px; font-size:13px; }
        .add-box button { background: var(--success); color:#fff; border:none; padding:10px 18px; border-radius:8px; cursor:pointer; font-weight:700; }
        .empty-row { text-align:center; color: var(--text-dim); padding: 24px !important; }
      </style>
    </head>
    <body>
      <div class="wrap">
        <div class="nav">
          <div class="nav-links">
            <a href="/" class="${activeNav === 'dashboard' ? 'active' : ''}"><i class="fa-solid fa-house"></i> Dashboard</a>
            <a href="/employees" class="${activeNav === 'employees' ? 'active' : ''}"><i class="fa-solid fa-user-shield"></i> Nhân viên</a>
            <a href="/shifts" class="${activeNav === 'shifts' ? 'active' : ''}"><i class="fa-solid fa-clock"></i> Ca làm việc</a>
          </div>
          <button class="theme-btn" onclick="toggleTheme()"><i class="fa-solid fa-moon"></i> Giao diện</button>
        </div>
        ${bodyHtml}
      </div>
      <script>
        function toggleTheme() {
          const cur = document.documentElement.getAttribute('data-theme');
          const next = cur === 'dark' ? 'light' : 'dark';
          document.documentElement.setAttribute('data-theme', next);
          localStorage.setItem('theme', next);
        }
        const saved = localStorage.getItem('theme');
        if (saved === 'dark') document.documentElement.setAttribute('data-theme', 'dark');
      </script>
    </body>
    </html>`;
}

app.get("/employees", requireAdminAuth, (req, res) => {
  db.all("SELECT * FROM employees ORDER BY id ASC", (err, employees) => {
    const rows = (employees || []).map(e => `
      <tr>
        <td>${e.employee_id}</td>
        <td>${e.name || ''}</td>
        <td><span class="status-dot ${e.active === 1 ? 'dot-online' : 'dot-offline'}"></span> ${e.active === 1 ? 'Hoạt động' : 'Đã khóa'}</td>
        <td style="display:flex; gap:6px; flex-wrap:wrap;">
          <form method="POST" action="/employees/reset-password" onsubmit="const p = prompt('Nhập mật khẩu MỚI cho ${e.employee_id}:'); if(!p) return false; this.password.value = p;" style="display:inline">
            <input type="hidden" name="id" value="${e.id}">
            <input type="hidden" name="password" value="">
            <button type="submit" class="control-btn"><i class="fa-solid fa-key"></i> Đổi MK</button>
          </form>
          <form method="POST" action="/employees/toggle-active" style="display:inline">
            <input type="hidden" name="id" value="${e.id}">
            <button type="submit" class="control-btn ${e.active === 1 ? 'btn-warn' : 'btn-ok'}">
              <i class="fa-solid ${e.active === 1 ? 'fa-lock' : 'fa-lock-open'}"></i> ${e.active === 1 ? 'Khóa' : 'Mở khóa'}
            </button>
          </form>
          <form method="POST" action="/employees/delete" onsubmit="return confirm('Xóa vĩnh viễn tài khoản ${e.employee_id}?');" style="display:inline">
            <input type="hidden" name="id" value="${e.id}">
            <button type="submit" class="control-btn btn-close"><i class="fa-solid fa-trash"></i> Xóa</button>
          </form>
        </td>
      </tr>`).join("");

    const body = `
      <h1><i class="fa-solid fa-user-shield"></i> Quản lý tài khoản Nhân viên</h1>
      <p class="subtitle">Tài khoản dùng để đăng nhập trên App Nhân viên (App Bảo vệ).</p>
      <table>
        <thead><tr><th>Tài khoản</th><th>Tên</th><th>Trạng thái</th><th>Thao tác</th></tr></thead>
        <tbody>${rows || '<tr><td colspan="4" class="empty-row">Chưa có tài khoản nào</td></tr>'}</tbody>
      </table>
      <div class="add-box">
        <h3>Thêm tài khoản nhân viên mới</h3>
        <form method="POST" action="/employees/add">
          <input type="text" name="employee_id" placeholder="Mã tài khoản (VD: NV4)" required>
          <input type="text" name="name" placeholder="Tên nhân viên">
          <input type="text" name="password" placeholder="Mật khẩu" required>
          <button type="submit"><i class="fa-solid fa-plus"></i> Thêm</button>
        </form>
      </div>`;

    res.send(renderAdminPage("Quản lý Nhân viên", "employees", body));
  });
});

// Trang xem lịch sử ca làm việc của TẤT CẢ nhân viên (Admin xem để kiểm tra/đối chiếu)
app.get("/shifts", requireAdminAuth, (req, res) => {
  db.all("SELECT * FROM shifts ORDER BY id DESC LIMIT 200", (err, shifts) => {
    const fmt = (ms) => {
      if (!ms) return "--";
      const d = new Date(Number(ms));
      const pad = (n) => n.toString().padStart(2, "0");
      return `${pad(d.getHours())}:${pad(d.getMinutes())} ${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${d.getFullYear()}`;
    };
    const fmtMoney = (n) => (n || 0).toLocaleString("vi-VN") + "đ";

    const rows = (shifts || []).map(s => `
      <tr>
        <td><b>${s.employee_id}</b><br><span style="color:var(--text-dim); font-size:11px;">${s.employee_name || ''}</span></td>
        <td>${fmt(s.start_time)}</td>
        <td>${fmt(s.end_time)}</td>
        <td>${s.entry_count || 0} xe</td>
        <td>${s.exit_count || 0} xe</td>
        <td><b>${fmtMoney(s.revenue)}</b></td>
      </tr>`).join("");

    const body = `
      <h1><i class="fa-solid fa-clock"></i> Lịch sử Ca làm việc</h1>
      <p class="subtitle">Ghi nhận mỗi khi nhân viên bấm "Kết thúc ca" trên App Nhân viên - dùng để kiểm tra/đối chiếu giờ làm.</p>
      <table>
        <thead><tr><th>Nhân viên</th><th>Bắt đầu</th><th>Kết thúc</th><th>Xe vào</th><th>Xe ra</th><th>Doanh thu</th></tr></thead>
        <tbody>${rows || '<tr><td colspan="6" class="empty-row">Chưa có ca làm việc nào được ghi nhận</td></tr>'}</tbody>
      </table>`;

    res.send(renderAdminPage("Lịch sử Ca làm việc", "shifts", body));
  });
});

// Render Dashboard Web Admin
app.get("/", requireAdminAuth, (req, res) => {
  db.all("SELECT * FROM cars ORDER BY active DESC, id DESC", (err, rows) => {
    db.all(`SELECT u.id, u.username, u.name, u.balance, GROUP_CONCAT(p.plate, ',') as plates 
            FROM users u LEFT JOIN plates p ON u.id = p.user_id GROUP BY u.id ORDER BY u.id DESC`, (err, users) => {
      db.all("SELECT * FROM server_logs ORDER BY id DESC LIMIT 100", (err, logs) => {
        
        let parkedCars = rows ? rows.filter(r => r.active === 1).length : 0;
        let availableSlots = getAvailableSlots(); 
        const sensorOccupied = MAX_CARS - availableSlots;
        
        const isParkingFull = parkedCars >= MAX_CARS || sensorOccupied >= MAX_CARS;
        const dataMismatch = sensorOccupied !== parkedCars;

        // DOANH THU CHỈ TÍNH CÁC PHIÊN ĐÃ PAID
        const collectedRevenue = rows ? rows.reduce((sum, r) => sum + (r.payment_status === 'PAID' ? (r.fee || 0) : 0), 0) : 0;

        const safeRows = rows || [];
        const safeUsers = users || [];
        const safeLogs = logs || [];

        let html = `
          <!DOCTYPE html>
          <html lang="vi" data-theme="light">
          <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Smart Parking Management OS</title>
            <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@300;400;500;600;700;800&display=swap" rel="stylesheet">
            <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
            <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
            <script src="/socket.io/socket.io.js"></script>
            <style>
              :root {
                --primary: #0ea5e9;
                --primary-dark: #0284c7;
                --primary-light: #e0f2fe;
                --bg-deep: #f0f9ff;
                --card-bg: #ffffff;
                --text-bright: #0f172a;
                --text-dim: #64748b;
                --border: #bae6fd;
                --shadow: rgba(14, 165, 233, 0.08);
                --success: #10b981;
                --danger: #ef4444;
                --warning: #f59e0b;
              }

              [data-theme="dark"] {
                --primary: #38bdf8;
                --primary-dark: #0284c7;
                --primary-light: rgba(56, 189, 248, 0.15);
                --bg-deep: #0A192F;
                --card-bg: #112240;
                --text-bright: #f8fafc;
                --text-dim: #94a3b8;
                --border: #233554;
                --shadow: rgba(0, 0, 0, 0.25);
              }

              * { margin: 0; padding: 0; box-sizing: border-box; font-family: 'Plus Jakarta Sans', sans-serif; transition: background-color 0.25s, border-color 0.25s; }
              body { background: var(--bg-deep); color: var(--text-bright); min-height: 100vh; padding: 20px; }
              .container { width: 100%; max-width: 1400px; margin: 0 auto; }

              .header { display: flex; justify-content: space-between; align-items: center; padding: 18px 25px; background: var(--card-bg); border-radius: 20px; border: 1px solid var(--border); box-shadow: 0 10px 25px -5px var(--shadow); margin-bottom: 25px; }
              .header-brand { display: flex; align-items: center; gap: 12px; }
              .header-brand i { font-size: 1.8rem; color: var(--primary); }
              .header-brand h1 { font-size: 1.3rem; font-weight: 800; letter-spacing: -0.5px; background: linear-gradient(135deg, var(--primary), var(--primary-dark)); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
              .header-actions { display: flex; align-items: center; gap: 15px; }

              .sys-status { display: flex; gap: 10px; align-items: center; font-size: 0.75rem; font-weight: 700; padding: 6px 12px; background: var(--bg-deep); border-radius: 20px; border: 1px solid var(--border); }
              .status-dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; }
              .dot-online { background: var(--success); }
              .dot-offline { background: var(--danger); }

              .theme-toggle { background: var(--primary-light); border: 1px solid var(--border); color: var(--primary); padding: 8px 16px; border-radius: 30px; font-weight: 700; cursor: pointer; display: flex; align-items: center; gap: 8px; font-size: 0.85rem; }

              .nav-tabs { display: flex; gap: 10px; margin-bottom: 25px; border-bottom: 2px solid var(--border); padding-bottom: 12px; flex-wrap: wrap; }
              .nav-btn { background: transparent; border: none; font-size: 0.95rem; font-weight: 700; color: var(--text-dim); cursor: pointer; padding: 10px 20px; border-radius: 12px; transition: 0.2s; display: flex; align-items: center; gap: 8px; }
              .nav-btn.active { background: var(--primary); color: white; box-shadow: 0 4px 12px var(--shadow); }

              .tab-content { display: none; animation: fadeIn 0.3s forwards; }
              .tab-content.active { display: block; }
              @keyframes fadeIn { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: translateY(0); } }

              .grid-layout { display: grid; grid-template-columns: 1fr 340px; gap: 20px; }
              .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 20px; }
              .stat-card { background: var(--card-bg); padding: 20px; border-radius: 18px; border: 1px solid var(--border); box-shadow: 0 4px 12px var(--shadow); position: relative; overflow: hidden; }
              .stat-card .label { color: var(--text-dim); font-size: 0.75rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px; }
              .stat-card .value { font-size: 1.8rem; font-weight: 800; margin-top: 8px; display: block; }
              .stat-card i.bg-icon { position: absolute; right: -10px; bottom: -10px; font-size: 4rem; opacity: 0.08; color: var(--text-bright); }

              .slots-container { background: var(--card-bg); padding: 22px; border-radius: 20px; border: 1px solid var(--border); box-shadow: 0 4px 12px var(--shadow); margin-bottom: 25px; }
              .slots-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); gap: 15px; }
              .slot-box { background: var(--bg-deep); padding: 20px 15px; border-radius: 16px; text-align: center; border: 2px dashed var(--border); }
              .slot-box.occupied { border-style: solid; border-color: var(--danger); color: var(--danger); background: rgba(239, 68, 68, 0.08); }
              .slot-box.empty { border-style: solid; border-color: var(--success); color: var(--success); background: rgba(16, 185, 129, 0.08); }
              .slot-box i { font-size: 2rem; margin-bottom: 8px; }

              .control-panel { background: var(--card-bg); padding: 20px; border-radius: 20px; border: 1px solid var(--border); box-shadow: 0 4px 12px var(--shadow); }
              .control-btn { width: 100%; padding: 12px; border-radius: 12px; border: none; color: white; font-weight: 800; cursor: pointer; margin-bottom: 10px; display: flex; align-items: center; justify-content: center; gap: 8px; font-size: 0.85rem; transition: transform 0.1s, opacity 0.2s; }
              .control-btn:active { transform: scale(0.98); }
              .btn-open { background: var(--primary); }
              .btn-hold { background: var(--warning); }
              .btn-close { background: var(--danger); }
              .btn-reset { background: transparent; border: 1px solid var(--border); color: var(--text-dim); }
              .btn-reset:hover { background: var(--bg-deep); color: var(--text-bright); }

              .alert-banner { padding: 12px 16px; border-radius: 12px; font-weight: 700; font-size: 0.85rem; margin-bottom: 20px; display: flex; align-items: center; gap: 10px; }
              .alert-full { background: rgba(239, 68, 68, 0.15); border: 1px solid var(--danger); color: var(--danger); }
              .alert-mismatch { background: rgba(245, 158, 11, 0.15); border: 1px solid var(--warning); color: var(--warning); }

              .filter-bar { display: flex; gap: 12px; background: var(--card-bg); padding: 15px 20px; border-radius: 16px; border: 1px solid var(--border); margin-bottom: 20px; flex-wrap: wrap; align-items: center; }
              .filter-group { display: flex; align-items: center; gap: 8px; }
              .filter-group label { font-size: 0.8rem; font-weight: 700; color: var(--text-dim); }
              .filter-select { padding: 8px 12px; border-radius: 8px; border: 1px solid var(--border); background: var(--bg-deep); color: var(--text-bright); font-size: 0.85rem; outline: none; font-weight: 600; }

              .charts-grid { display: grid; grid-template-columns: 2fr 1fr; gap: 20px; margin-bottom: 25px; }
              .chart-card { background: var(--card-bg); padding: 20px; border-radius: 20px; border: 1px solid var(--border); box-shadow: 0 4px 12px var(--shadow); }

              .table-section { background: var(--card-bg); border-radius: 20px; overflow: hidden; border: 1px solid var(--border); box-shadow: 0 4px 12px var(--shadow); margin-bottom: 25px; }
              .table-toolbar { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 18px 20px; border-bottom: 1px solid var(--border); flex-wrap: wrap; }
              .search-box { position: relative; flex: 1; min-width: 220px; max-width: 360px; }
              .search-box i { position: absolute; left: 14px; top: 50%; transform: translateY(-50%); color: var(--text-dim); }
              .search-box input { width: 100%; padding: 10px 14px 10px 36px; border: 1px solid var(--border); border-radius: 10px; background: var(--bg-deep); color: var(--text-bright); outline: none; font-size: 0.85rem; }
              .table-wrapper { overflow-x: auto; }
              table { width: 100%; border-collapse: collapse; min-width: 900px; }
              th { padding: 14px 20px; text-align: left; font-size: 0.75rem; color: var(--text-dim); text-transform: uppercase; background: var(--bg-deep); font-weight: 800; letter-spacing: 0.5px; }
              td { padding: 14px 20px; font-size: 0.85rem; border-bottom: 1px solid var(--border); color: var(--text-bright); }
              tbody tr:hover { background: var(--primary-light); }
              tbody tr.row-hidden { display: none; }
              .badge { padding: 5px 10px; border-radius: 6px; font-size: 0.7rem; font-weight: 700; display: inline-block; }
              .badge-active { background: rgba(16, 185, 129, 0.15); color: var(--success); }
              .badge-inactive { background: rgba(100, 116, 139, 0.15); color: var(--text-dim); }
              .badge-paid { background: rgba(16, 185, 129, 0.15); color: var(--success); }
              .badge-pending { background: rgba(245, 158, 11, 0.15); color: var(--warning); }

              .input-form { display: flex; gap: 10px; flex-wrap: wrap; }
              .input-form input { padding: 10px 14px; border: 1px solid var(--border); border-radius: 10px; background: var(--bg-deep); color: var(--text-bright); outline: none; font-size: 0.85rem; flex: 1; min-width: 160px; }
              .plate-tag { display: inline-flex; align-items: center; background: var(--primary-light); color: var(--primary); padding: 4px 10px; border-radius: 6px; margin: 2px 4px 2px 0; font-size: 0.8rem; font-weight: 700; border: 1px solid var(--border); }
              .plate-tag button { background: none; border: none; color: var(--danger); margin-left: 6px; cursor: pointer; }
            </style>
          </head>
          <body>
            <div class="container">
              <div class="header">
                <div class="header-brand">
                  <i class="fa-solid fa-square-parking"></i>
                  <div>
                    <h1>PARK-OS PLATFORM</h1>
                    <span style="font-size:0.75rem; color:var(--text-dim); font-weight:600;">Hệ Thống Quản Lý Bãi Đỗ Xe Thông Minh</span>
                  </div>
                </div>

                <div class="header-actions">
                  <a href="/shifts" class="theme-toggle" style="text-decoration:none;">
                    <i class="fa-solid fa-clock"></i>
                    <span>Ca làm việc</span>
                  </a>
                  <a href="/employees" class="theme-toggle" style="text-decoration:none;">
                    <i class="fa-solid fa-user-shield"></i>
                    <span>Quản lý Nhân viên</span>
                  </a>
                  <button class="theme-toggle" onclick="toggleTheme()">
                    <i class="fa-solid fa-moon" id="themeIcon"></i>
                    <span id="themeText">Giao Diện Tối</span>
                  </button>
                </div>
              </div>

              <div class="nav-tabs">
                <button class="nav-btn active" onclick="switchTab('tab-overview', this)"><i class="fa-solid fa-gauge-high"></i> Giám Sát Live</button>
                <button class="nav-btn" onclick="switchTab('tab-analytics', this)"><i class="fa-solid fa-chart-line"></i> Báo Cáo Doanh Thu</button>
                <button class="nav-btn" onclick="switchTab('tab-users', this)"><i class="fa-solid fa-users-gear"></i> Khách Hàng & Ví</button>
                <button class="nav-btn" onclick="switchTab('tab-history', this)"><i class="fa-solid fa-clock-rotate-left"></i> Lịch Sử Lượt Xe</button>
                <button class="nav-btn" onclick="switchTab('tab-logs', this)"><i class="fa-solid fa-list-check"></i> Log Server</button>
                <button class="nav-btn" onclick="switchTab('tab-settings', this)"><i class="fa-solid fa-sliders"></i> Cài Đặt</button>
              </div>

              <!-- TAB 1: GIÁM SÁT LIVE -->
              <div id="tab-overview" class="tab-content active">
                ${isParkingFull ? `
                <div class="alert-banner alert-full">
                  <i class="fa-solid fa-triangle-exclamation fa-lg"></i> 🔴 CẢNH BÁO: BÃI ĐÃ ĐẦY! Hệ thống tạm ngưng nhận xe vào theo quy trình bình thường.
                </div>` : ''}

                ${dataMismatch ? `
                <div class="alert-banner alert-mismatch">
                  <i class="fa-solid fa-circle-exclamation fa-lg"></i> ⚠ CẢNH BÁO LỆCH DỮ LIỆU: CSDL ghi nhận ${parkedCars} xe, Cảm biến báo ${sensorOccupied} vị trí có xe.
                </div>` : ''}

                <div class="grid-layout">
                  <div class="main-content">
                    <div class="stats-grid">
                      <div class="stat-card">
                        <span class="label">Xe Đang Trong Bãi</span>
                        <span class="value" style="color:var(--primary)">${parkedCars} <small style="font-size:0.8rem">xe</small></span>
                        <i class="fa-solid fa-car bg-icon"></i>
                      </div>
                      <div class="stat-card">
                        <span class="label">Vị Trí Còn Trống</span>
                        <span class="value" style="color:var(--success)">${availableSlots}/${MAX_CARS}</span>
                        <i class="fa-solid fa-square-check bg-icon"></i>
                      </div>
                      <div class="stat-card">
                        <span class="label">Doanh Thu Đã Thu</span>
                        <span class="value" style="color:var(--success)">${collectedRevenue.toLocaleString()} <small style="font-size:0.8rem">đ</small></span>
                        <i class="fa-solid fa-wallet bg-icon"></i>
                      </div>
                    </div>

                    <div class="slots-container">
                      <h3 style="font-size: 0.9rem; color: var(--text-dim); font-weight:800; margin-bottom: 15px; text-transform:uppercase;">Trạng Thái Cảm Biến Trực Tuyến</h3>
                      <div class="slots-grid">
                        <div class="slot-box ${slot1Occupied ? 'occupied' : 'empty'}">
                          <i class="fa-solid ${slot1Occupied ? 'fa-car' : 'fa-circle-check'}"></i>
                          <div style="font-weight: 800;">VỊ TRÍ 01</div>
                          <small style="font-size:0.7rem;">${slot1Occupied ? 'CÓ XE' : 'TRỐNG'}</small>
                        </div>
                        <div class="slot-box ${slot2Occupied ? 'occupied' : 'empty'}">
                          <i class="fa-solid ${slot2Occupied ? 'fa-car' : 'fa-circle-check'}"></i>
                          <div style="font-weight: 800;">VỊ TRÍ 02</div>
                          <small style="font-size:0.7rem;">${slot2Occupied ? 'CÓ XE' : 'TRỐNG'}</small>
                        </div>
                        <div class="slot-box ${slot3Occupied ? 'occupied' : 'empty'}">
                          <i class="fa-solid ${slot3Occupied ? 'fa-car' : 'fa-circle-check'}"></i>
                          <div style="font-weight: 800;">VỊ TRÍ 03</div>
                          <small style="font-size:0.7rem;">${slot3Occupied ? 'CÓ XE' : 'TRỐNG'}</small>
                        </div>
                        <div class="slot-box ${slot4Occupied ? 'occupied' : 'empty'}">
                          <i class="fa-solid ${slot4Occupied ? 'fa-car' : 'fa-circle-check'}"></i>
                          <div style="font-weight: 800;">VỊ TRÍ 04</div>
                          <small style="font-size:0.7rem;">${slot4Occupied ? 'CÓ XE' : 'TRỐNG'}</small>
                        </div>
                      </div>
                    </div>
                  </div>

                  <div class="side-panel">
                    <div class="control-panel">
                      <div style="text-align: center; margin-bottom: 15px;">
                        <span style="font-size: 0.75rem; color: var(--text-dim); font-weight: 700; text-transform:uppercase;">CỔNG BARRIER</span>
                        <div style="font-weight: 800; font-size:1.1rem; margin-top: 5px; color: ${barrierOpen ? 'var(--success)' : 'var(--danger)'}">
                          <i class="fa-solid ${barrierOpen ? 'fa-lock-open' : 'fa-lock'}"></i> ${barrierOpen ? 'ĐANG MỞ' : 'ĐANG ĐÓNG'}
                        </div>
                      </div>
                      <form method="POST" action="/open-auto"><button class="control-btn btn-open"><i class="fa-solid fa-bolt"></i> MỞ TỰ ĐỘNG (5S)</button></form>
                      
                      <form method="POST" action="/open-manual">
                        <button class="control-btn btn-hold"><i class="fa-solid fa-key"></i> MỞ THỦ CÔNG (GIỮ CỔNG)</button>
                      </form>

                      <form method="POST" action="/close"><button class="control-btn btn-close"><i class="fa-solid fa-shield-halved"></i> ĐÓNG KHẨN CẤP</button></form>
                      <form method="POST" action="/reset-all" onsubmit="return confirm('ADMIN: Xác nhận reset toàn bộ nhật ký bãi xe? Hành động sẽ ghi Log.');"><button class="control-btn btn-reset" style="margin-top:15px"><i class="fa-solid fa-arrows-rotate"></i> RESET NHẬT KÝ</button></form>
                    </div>
                  </div>
                </div>
              </div>

              <!-- TAB 2: BÁO CÁO DOANH THU -->
              <div id="tab-analytics" class="tab-content">
                <div class="filter-bar">
                  <div class="filter-group">
                    <label><i class="fa-solid fa-filter"></i> Lọc Theo:</label>
                    <select id="reportTimeRange" class="filter-select" onchange="updateDashboardAnalytics()">
                      <option value="all">Tất cả thời gian</option>
                      <option value="today">Hôm nay</option>
                      <option value="month">Tháng này</option>
                    </select>
                  </div>
                  <div class="filter-group">
                    <label>Phương Thức:</label>
                    <select id="reportCustomerType" class="filter-select" onchange="updateDashboardAnalytics()">
                      <option value="all">Tất cả</option>
                      <option value="wallet">Ví Điện Tử (WALLET)</option>
                      <option value="cash">Tiền Mặt (CASH)</option>
                    </select>
                  </div>
                </div>

                <div class="stats-grid">
                  <div class="stat-card">
                    <span class="label">Tổng Lượt Xe Hoàn Tất</span>
                    <span class="value" id="kpiTotalVisits" style="color:var(--primary)">0</span>
                  </div>
                  <div class="stat-card">
                    <span class="label">Doanh Thu Đã Thu</span>
                    <span class="value" id="kpiFilteredRevenue" style="color:var(--success)">0 đ</span>
                  </div>
                  <div class="stat-card">
                    <span class="label">Thanh Toán Ví</span>
                    <span class="value" id="kpiWalletVisits" style="color:var(--primary)">0</span>
                  </div>
                  <div class="stat-card">
                    <span class="label">Thanh Toán Tiền Mặt</span>
                    <span class="value" id="kpiCasualVisits" style="color:var(--text-dim)">0</span>
                  </div>
                </div>

                <div class="charts-grid">
                  <div class="chart-card">
                    <h3><i class="fa-solid fa-chart-area"></i> Biểu Đồ Tăng Trưởng Doanh Thu</h3>
                    <canvas id="revenueChart" height="110"></canvas>
                  </div>
                  <div class="chart-card">
                    <h3><i class="fa-solid fa-chart-pie"></i> Cơ Cấu Phương Thức Thanh Toán</h3>
                    <canvas id="customerPieChart" height="200"></canvas>
                  </div>
                </div>
              </div>

              <!-- TAB 3: KHÁCH HÀNG & VÍ -->
              <div id="tab-users" class="tab-content">
                <div class="table-section" style="padding: 22px;">
                  <h3 style="margin-bottom: 15px; color: var(--primary); font-size: 1.05rem;"><i class="fa-solid fa-user-plus"></i> Đăng Ký Tài Khoản Khách Hàng</h3>
                  <form method="POST" action="/users/add" class="input-form">
                    <input type="text" name="name" placeholder="Tên khách hàng" required>
                    <input type="password" name="password" placeholder="Mật khẩu App" required>
                    <input type="text" name="plates" placeholder="Nhập biển số (VD: 51A12345, 30B22222)" required style="flex:2;">
                    <input type="number" name="balance" placeholder="Số dư ban đầu (VNĐ)" required>
                    <button type="submit" class="control-btn btn-open" style="width: auto; margin:0; padding:0 25px;"><i class="fa-solid fa-save"></i> TẠO TÀI KHOẢN</button>
                  </form>
                </div>

                <div class="table-section">
                  <div class="table-toolbar">
                    <div class="search-box">
                      <i class="fa-solid fa-magnifying-glass"></i>
                      <input type="text" id="usersSearch" placeholder="Tìm tên, mã KH, biển số..." oninput="filterTable('usersTable', this.value)">
                    </div>
                    <span style="color:var(--text-dim); font-size:0.8rem; font-weight:700;">${safeUsers.length} khách hàng</span>
                  </div>
                  <div class="table-wrapper">
                    <table id="usersTable">
                      <thead>
                        <tr>
                          <th>MÃ KH</th>
                          <th>TÊN KHÁCH HÀNG</th>
                          <th>USERNAME</th>
                          <th>DANH SÁCH BIỂN SỐ</th>
                          <th>SỐ DƯ VÍ</th>
                          <th>NẠP/TRỪ VÍ</th>
                          <th style="text-align:right">THAO TÁC</th>
                        </tr>
                      </thead>
                      <tbody>
                        ${safeUsers.map(u => {
                          let plateHtml = '';
                          if (u.plates) {
                            u.plates.split(',').forEach(p => {
                              if(p) {
                                const safeP = escapeHtml(p);
                                plateHtml += `
                                <div class="plate-tag">
                                  ${safeP}
                                  <form method="POST" action="/users/plates/delete" style="display:inline;">
                                      <input type="hidden" name="plate" value="${safeP}">
                                      <button type="submit" title="Xóa biển" onclick="return confirm('Xóa biển ${safeP}?');"><i class="fa-solid fa-xmark"></i></button>
                                  </form>
                                </div>`;
                              }
                            });
                          } else {
                            plateHtml = `<span style="color:var(--text-dim); font-size: 0.8rem;">Chưa đăng ký</span>`;
                          }
                          
                          plateHtml += `
                          <form style="display:inline-flex; gap:4px; margin-top:5px;" method="POST" action="/users/plates/add">
                              <input type="hidden" name="user_id" value="${u.id}">
                              <input type="text" name="plate" placeholder="Thêm biển..." required style="padding:3px 6px; font-size:0.75rem; border:1px solid var(--border); border-radius:6px; background:var(--bg-deep); color:var(--text-bright); width:90px;">
                              <button type="submit" style="background:var(--success); color:white; border:none; border-radius:6px; padding:3px 8px; font-size:0.75rem; cursor:pointer;"><i class="fa-solid fa-plus"></i></button>
                          </form>`;

                          return `
                          <tr data-search="${escapeHtml(u.id + ' ' + u.username + ' ' + u.name + ' ' + (u.plates || ''))}">
                            <td style="color: var(--primary); font-weight:800;">#${u.id}</td>
                            <td style="font-weight: 700;">${escapeHtml(u.name)}</td>
                            <td style="font-family: monospace; color: var(--text-dim);">${escapeHtml(u.username)}</td>
                            <td>${plateHtml}</td>
                            <td style="font-weight: 800; color: var(--warning)">${u.balance ? u.balance.toLocaleString() : 0}đ</td>
                            <td>
                              <form method="POST" action="/users/balance" style="display:flex; gap:4px; align-items:center;">
                                <input type="hidden" name="id" value="${u.id}">
                                <input type="number" name="amount" value="50000" min="1000" style="width:80px; padding:4px 6px; border:1px solid var(--border); border-radius:6px; background:var(--bg-deep); color:var(--text-bright); font-size:0.8rem;">
                                <button type="submit" name="action" value="add" style="background:var(--success); color:white; border:none; border-radius:6px; width:26px; height:26px; cursor:pointer; font-weight:bold;">+</button>
                                <button type="submit" name="action" value="sub" style="background:var(--warning); color:white; border:none; border-radius:6px; width:26px; height:26px; cursor:pointer; font-weight:bold;">-</button>
                              </form>
                            </td>
                            <td style="text-align:right">
                              <form method="POST" action="/users/delete" onsubmit="return confirm('Xóa tài khoản này?');" style="display:inline;">
                                <input type="hidden" name="id" value="${u.id}">
                                <button type="submit" style="background:none; border:none; color:var(--danger); cursor:pointer;"><i class="fa-solid fa-trash-can fa-lg"></i></button>
                              </form>
                            </td>
                          </tr>`;
                        }).join('')}
                      </tbody>
                    </table>
                  </div>
                </div>
              </div>

              <!-- TAB 4: LỊCH SỬ LƯỢT XE -->
              <div id="tab-history" class="tab-content">
                <div class="table-section">
                  <div class="table-toolbar">
                    <div class="search-box">
                      <i class="fa-solid fa-magnifying-glass"></i>
                      <input type="text" id="historySearch" placeholder="Tìm biển số hoặc UID..." oninput="filterTable('historyTable', this.value)">
                    </div>
                    <span style="color:var(--text-dim); font-size:0.8rem; font-weight:700;">${safeRows.length} lượt đỗ</span>
                  </div>
                  <div class="table-wrapper">
                    <table id="historyTable">
                      <thead>
                        <tr>
                          <th>RFID / UID</th>
                          <th>BIỂN SỐ XE</th>
                          <th>GIỜ VÀO</th>
                          <th>GIỜ RA</th>
                          <th>CƯỚC PHÍ</th>
                          <th>THANH TOÁN</th>
                          <th>TRẠNG THÁI TT</th>
                          <th>BÃI ĐỖ</th>
                          <th style="text-align:right">THAO TÁC KHẨN CẤP</th>
                        </tr>
                      </thead>
                      <tbody>
                        ${safeRows.map(r => `
                          <tr data-search="${escapeHtml((r.plate || '') + ' ' + (r.uid || ''))}">
                            <td style="font-family: monospace; color: var(--primary); font-weight:700">${escapeHtml(r.uid)}</td>
                            <td><b style="letter-spacing: 0.5px;">${escapeHtml(r.plate)}</b></td>
                            <td style="color: var(--text-dim)">${r.time_in ? new Date(r.time_in).toLocaleString('vi-VN') : '--'}</td>
                            <td style="color: var(--text-dim)">${r.time_out ? new Date(r.time_out).toLocaleString('vi-VN') : '--'}</td>
                            <td style="font-weight: 800; color: var(--warning)">${r.fee ? r.fee.toLocaleString() + 'đ' : '--'}</td>
                            <td><span class="badge" style="background:var(--bg-deep); border:1px solid var(--border); color:var(--text-bright);">${escapeHtml(r.payment_method) || '--'}</span></td>
                            <td><span class="badge ${r.payment_status === 'PAID' ? 'badge-paid' : 'badge-pending'}">${r.payment_status === 'PAID' ? 'ĐÃ THU' : 'CHỜ THU'}</span></td>
                            <td><span class="badge ${r.active ? 'badge-active' : 'badge-inactive'}">${r.active ? 'TRONG BÃI' : 'ĐÃ RA'}</span></td>
                            <td style="text-align:right">
                              <div style="display: flex; gap: 10px; justify-content: flex-end; align-items:center;">
                                ${r.active ? `
                                  <form method="POST" action="/force-checkout" style="display:inline" onsubmit="const reason = prompt('NHẬP LÝ DO XỬ LÝ KHẨN CẤP (Bắt buộc):'); if(!reason) return false; this.reason.value = reason;">
                                    <input type="hidden" name="id" value="${r.id}">
                                    <input type="hidden" name="reason" value="">
                                    <button type="submit" style="background:none; border:none; color:var(--primary); cursor:pointer" title="Cho xe ra khẩn cấp"><i class="fa-solid fa-triangle-exclamation fa-lg"></i></button>
                                  </form>` : ''}
                                <form method="POST" action="/delete" onsubmit="return confirm('Xóa lượt xe này? Thao tác sẽ được lưu Log.');" style="display:inline">
                                  <input type="hidden" name="id" value="${r.id}">
                                  <button type="submit" style="background:none; border:none; color:var(--danger); cursor:pointer"><i class="fa-solid fa-trash-can fa-lg"></i></button>
                                </form>
                              </div>
                            </td>
                          </tr>
                        `).join('')}
                      </tbody>
                    </table>
                  </div>
                </div>
              </div>

              <!-- TAB 5: LOG SERVER -->
              <div id="tab-logs" class="tab-content">
                <div class="table-section">
                  <div class="table-toolbar">
                    <div class="search-box">
                      <i class="fa-solid fa-magnifying-glass"></i>
                      <input type="text" id="logsSearch" placeholder="Tìm nhật ký thao tác..." oninput="filterTable('logsTable', this.value)">
                    </div>
                    <span style="color:var(--text-dim); font-size:0.8rem; font-weight:700;">${safeLogs.length} nhật ký</span>
                  </div>
                  <div class="table-wrapper">
                    <table id="logsTable">
                      <thead>
                        <tr>
                          <th>STT</th>
                          <th>THỜI GIAN</th>
                          <th>HÀNH ĐỘNG</th>
                          <th>CHI TIẾT THAO TÁC & LÝ DO</th>
                        </tr>
                      </thead>
                      <tbody>
                        ${safeLogs.map(l => `
                          <tr data-search="${escapeHtml((l.action || '') + ' ' + (l.details || ''))}">
                            <td style="color: var(--primary); font-weight:800;">#${l.id}</td>
                            <td style="color: var(--text-dim); font-size: 0.8rem;">${l.timestamp ? new Date(l.timestamp).toLocaleString('vi-VN') : '--'}</td>
                            <td><span class="badge" style="background:var(--primary-light); color:var(--primary); font-weight:800;">${escapeHtml(l.action)}</span></td>
                            <td style="font-weight: 600;">${escapeHtml(l.details)}</td>
                          </tr>
                        `).join('')}
                      </tbody>
                    </table>
                  </div>
                </div>
              </div>

              <!-- TAB 6: CÀI ĐẶT GIÁ PHÍ -->
              <div id="tab-settings" class="tab-content">
                <div class="stats-grid">
                  <div class="stat-card">
                    <span class="label">Phí Giờ Đầu Tiên (hiện tại)</span>
                    <span class="value" style="color:var(--primary)">${BASE_FEE.toLocaleString()}đ</span>
                    <i class="fa-solid fa-coins bg-icon"></i>
                  </div>
                  <div class="stat-card">
                    <span class="label">Phí Mỗi Giờ Tiếp Theo (hiện tại)</span>
                    <span class="value" style="color:var(--warning)">${HOURLY_RATE.toLocaleString()}đ</span>
                    <i class="fa-solid fa-clock bg-icon"></i>
                  </div>
                </div>

                <div class="control-panel" style="max-width:560px;">
                  <h3 style="margin-bottom:6px; font-size:1.05rem;"><i class="fa-solid fa-sliders" style="color:var(--primary); margin-right:8px;"></i>Cấu Hình Giá Phí Gửi Xe</h3>
                  <p style="color:var(--text-dim); font-size:0.82rem; margin-bottom:18px; line-height:1.5;">
                    Mỗi bãi xe có thể có mức giá khác nhau. Thay đổi tại đây sẽ áp dụng NGAY cho mọi lượt tính phí mới
                    (không ảnh hưởng tới các lượt đã tính phí trước đó). Cách tính: giờ đầu tiên thu "Phí giờ đầu",
                    mỗi giờ phát sinh thêm sau đó thu "Phí mỗi giờ tiếp theo" (làm tròn lên theo giờ).
                  </p>
                  <form method="POST" action="/settings/fee" class="input-form" style="flex-direction:column; align-items:stretch;"
                        onsubmit="return confirm('Xác nhận cập nhật giá phí mới cho toàn bộ bãi xe?');">
                    <div>
                      <label style="display:block; font-size:0.8rem; font-weight:700; color:var(--text-dim); margin-bottom:6px;">
                        Phí giờ đầu tiên (VNĐ)
                      </label>
                      <input type="number" name="base_fee" min="0" step="500" required value="${BASE_FEE}" style="width:100%;">
                    </div>
                    <div>
                      <label style="display:block; font-size:0.8rem; font-weight:700; color:var(--text-dim); margin-bottom:6px;">
                        Phí mỗi giờ tiếp theo (VNĐ)
                      </label>
                      <input type="number" name="hourly_rate" min="0" step="500" required value="${HOURLY_RATE}" style="width:100%;">
                    </div>
                    <button type="submit" class="control-btn btn-open" style="margin-top:10px;">
                      <i class="fa-solid fa-floppy-disk"></i> Lưu Cấu Hình Giá
                    </button>
                  </form>
                </div>
              </div>

            </div>

            <script>
              const rawData = ${JSON.stringify(safeRows)};
              let revenueChartInstance = null;
              let customerPieChartInstance = null;

              function switchTab(tabId, btnElement) {
                document.querySelectorAll('.tab-content').forEach(tab => tab.classList.remove('active'));
                document.querySelectorAll('.nav-btn').forEach(btn => btn.classList.remove('active'));
                
                document.getElementById(tabId).classList.add('active');
                btnElement.classList.add('active');
                localStorage.setItem('activeTab', tabId);

                if (tabId === 'tab-analytics') {
                  updateDashboardAnalytics();
                }
              }

              function toggleTheme() {
                const currentTheme = document.documentElement.getAttribute('data-theme');
                const newTheme = currentTheme === 'dark' ? 'light' : 'dark';
                document.documentElement.setAttribute('data-theme', newTheme);
                localStorage.setItem('theme', newTheme);
                
                const icon = document.getElementById('themeIcon');
                const text = document.getElementById('themeText');
                if (newTheme === 'dark') {
                  icon.className = 'fa-solid fa-sun';
                  text.innerText = 'Giao Diện Sáng';
                } else {
                  icon.className = 'fa-solid fa-moon';
                  text.innerText = 'Giao Diện Tối';
                }
                if (document.getElementById('tab-analytics').classList.contains('active')) {
                  updateDashboardAnalytics();
                }
              }

              function filterTable(tableId, keyword) {
                const table = document.getElementById(tableId);
                if (!table) return;
                const kw = keyword.trim().toLowerCase();
                const rows = table.querySelectorAll('tbody tr');
                rows.forEach(row => {
                  const haystack = (row.getAttribute('data-search') || '').toLowerCase();
                  row.classList.toggle('row-hidden', kw !== '' && !haystack.includes(kw));
                });
                sessionStorage.setItem('search_' + tableId, keyword);
              }

              function updateDashboardAnalytics() {
                const range = document.getElementById('reportTimeRange').value;
                const custType = document.getElementById('reportCustomerType').value;
                const now = new Date();

                let filtered = rawData.filter(r => {
                  if (!r.time_in || r.payment_status !== 'PAID') return false; // Chỉ tính giao dịch đã PAID
                  const itemDate = new Date(r.paid_at || r.time_in);
                  
                  if (range === 'today') {
                    if (itemDate.toDateString() !== now.toDateString()) return false;
                  } else if (range === 'month') {
                    if (itemDate.getMonth() !== now.getMonth() || itemDate.getFullYear() !== now.getFullYear()) return false;
                  }

                  const pm = (r.payment_method || '').toUpperCase();
                  if (custType === 'wallet' && pm !== 'WALLET') return false;
                  if (custType === 'cash' && pm !== 'CASH') return false;

                  return true;
                });

                const totalVisits = filtered.length;
                const totalRev = filtered.reduce((sum, r) => sum + (r.fee || 0), 0);
                const walletCount = filtered.filter(r => (r.payment_method || '').toUpperCase() === 'WALLET').length;
                const cashCount = filtered.filter(r => (r.payment_method || '').toUpperCase() === 'CASH').length;

                document.getElementById('kpiTotalVisits').innerText = totalVisits;
                document.getElementById('kpiFilteredRevenue').innerText = totalRev.toLocaleString() + ' đ';
                document.getElementById('kpiWalletVisits').innerText = walletCount;
                document.getElementById('kpiCasualVisits').innerText = cashCount;

                renderCharts(filtered, walletCount, cashCount);
              }

              function renderCharts(dataList, walletCount, cashCount) {
                const isDark = document.documentElement.getAttribute('data-theme') === 'dark';
                const textColor = isDark ? '#94a3b8' : '#64748b';
                const primaryColor = isDark ? '#38bdf8' : '#0ea5e9';

                const revMap = {};
                dataList.forEach(r => {
                  const d = new Date(r.paid_at || r.time_in);
                  const label = (d.getMonth() + 1) + '/' + d.getDate();
                  revMap[label] = (revMap[label] || 0) + (r.fee || 0);
                });

                const labels = Object.keys(revMap).reverse();
                const chartData = labels.map(l => revMap[l]);

                const ctxLine = document.getElementById('revenueChart').getContext('2d');
                if (revenueChartInstance) revenueChartInstance.destroy();
                revenueChartInstance = new Chart(ctxLine, {
                  type: 'line',
                  data: {
                    labels: labels.length ? labels : ['Chưa có dữ liệu'],
                    datasets: [{
                      label: 'Doanh thu (VNĐ)',
                      data: chartData.length ? chartData : [0],
                      borderColor: primaryColor,
                      backgroundColor: 'rgba(14, 165, 233, 0.15)',
                      fill: true,
                      tension: 0.3
                    }]
                  },
                  options: {
                    responsive: true,
                    plugins: { legend: { display: false } },
                    scales: {
                      x: { ticks: { color: textColor } },
                      y: { ticks: { color: textColor } }
                    }
                  }
                });

                const ctxPie = document.getElementById('customerPieChart').getContext('2d');
                if (customerPieChartInstance) customerPieChartInstance.destroy();
                customerPieChartInstance = new Chart(ctxPie, {
                  type: 'doughnut',
                  data: {
                    labels: ['Ví điện tử', 'Tiền mặt'],
                    datasets: [{
                      data: [walletCount, cashCount],
                      backgroundColor: ['#10b981', '#0ea5e9']
                    }]
                  },
                  options: {
                    responsive: true,
                    plugins: { legend: { labels: { color: textColor } } }
                  }
                });
              }

              document.addEventListener("DOMContentLoaded", () => {
                const savedTheme = localStorage.getItem('theme');
                if (savedTheme === 'dark') toggleTheme();

                const savedTab = localStorage.getItem('activeTab');
                if (savedTab) {
                   const targetTab = document.getElementById(savedTab);
                   const targetBtn = document.querySelector('button[onclick*="' + savedTab + '"]');
                   if (targetTab && targetBtn) switchTab(savedTab, targetBtn);
                }

                const historyKw = sessionStorage.getItem('search_historyTable');
                if (historyKw) {
                  document.getElementById('historySearch').value = historyKw;
                  filterTable('historyTable', historyKw);
                }
              });

              const socket = io();
              socket.on("reload_data", () => {
                setTimeout(() => window.location.reload(), 400);
              });
            </script>
          </body>
          </html>`;
        res.send(html);
      });
    });
  });
});

server.listen(port, () => {
  console.log(`🚀 Server đỗ xe đã sẵn sàng tại: http://localhost:${port}`);
  console.log(`   (Dashboard Admin truy cập qua trình duyệt tại địa chỉ trên. App Mobile không cần biết IP này nữa - chỉ dùng MQTT.)`);
});