// ==========================================================
// SCRIPT NẠP DỮ LIỆU GIẢ (DEMO) VÀO DATABASE
// ==========================================================
// Mục đích: có ngay dữ liệu để test toàn bộ hệ thống (server dashboard, App nhân viên, App khách hàng)
// mà không cần chờ xe thật ra/vào qua ESP32.
//
// CÁCH DÙNG:
//   1. Đặt file này CÙNG THƯ MỤC với server.js (cùng chỗ có file parking.db)
//   2. TẮT server.js trước khi chạy (tránh xung đột ghi CSDL SQLite cùng lúc)
//   3. Chạy:  node seed-demo-data.js
//   4. Bật lại server.js như bình thường
//
// Script này AN TOÀN chạy lại nhiều lần - sẽ xóa sạch dữ liệu demo cũ (KHÔNG đụng vào bảng
// employees/requests/server_logs) trước khi nạp lại, tránh bị nhân đôi dữ liệu mỗi lần chạy.
//
// Biển số tuân thủ đúng quy chuẩn Việt Nam: 2 số đầu (mã tỉnh) + 1-2 chữ cái + 4-6 số,
// khớp với hàm isValidPlateFormat() đang dùng trong App Khách hàng:
//   ^[0-9]{2}[A-Z]{1,2}[0-9]{4,6}$
// ==========================================================

const sqlite3 = require("sqlite3").verbose();
const bcrypt = require("bcryptjs");

const db = new sqlite3.Database("parking.db");

// ---------- DANH SÁCH BIỂN SỐ MẪU ĐÚNG CHUẨN VN ----------
// Mã tỉnh phổ biến: 51/50 (TP.HCM), 29/30 (Hà Nội), 43 (Đà Nẵng), 60 (Đồng Nai), 61 (Bình Dương)...
const SAMPLE_PLATES = [
  "51A12345", "51G67890", "51K11111", "51F55555",
  "30A99999", "29A88888", "29H123456", "30G22222",
  "43A33333", "43H77777",
  "60A44444", "61B66666",
  "72A15975", "36A24680",
];

function randInt(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

function daysAgoMs(days, hour = 8) {
  const d = new Date();
  d.setDate(d.getDate() - days);
  d.setHours(hour, randInt(0, 59), 0, 0);
  return d.getTime();
}

// Định dạng "YYYY-MM-DD HH:MM:SS" - khớp CHÍNH XÁC với SQLite CURRENT_TIMESTAMP mà server.js thật đang dùng
// (recordWalletTransaction không tự truyền timestamp, để SQLite tự điền theo định dạng này).
function sqliteTimestampDaysAgo(days) {
  const d = new Date();
  d.setDate(d.getDate() - days);
  d.setHours(randInt(7, 20), randInt(0, 59), randInt(0, 59), 0);
  const pad = (n) => n.toString().padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

const DEMO_CUSTOMERS = [
  { username: "KHACHHANG1", name: "Nguyễn Văn An", password: "123456", balance: 250000, plates: ["51A12345", "51G67890"] },
  { username: "KHACHHANG2", name: "Trần Thị Bích", password: "123456", balance: 80000, plates: ["30A99999"] },
  { username: "KHACHHANG3", name: "Lê Minh Cường", password: "123456", balance: 500000, plates: ["29A88888", "29H123456"] },
  { username: "KHACHHANG4", name: "Phạm Thị Dung", password: "123456", balance: 15000, plates: ["43A33333"] },
  { username: "KHACHHANG5", name: "Hoàng Văn Em", password: "123456", balance: 0, plates: ["60A44444"] },
];

console.log("🌱 Bắt đầu nạp dữ liệu demo...");

db.serialize(() => {
  db.run("PRAGMA foreign_keys = ON");

  // ---------- XÓA DỮ LIỆU DEMO CŨ (an toàn chạy lại nhiều lần) ----------
  // Chỉ xóa cars/users/plates/wallet_transactions - KHÔNG đụng employees/server_logs/requests
  db.run("DELETE FROM wallet_transactions");
  db.run("DELETE FROM plates");
  db.run("DELETE FROM cars");
  db.run("DELETE FROM users");
  db.run("DELETE FROM sqlite_sequence WHERE name IN ('users','cars','wallet_transactions')");

  // ---------- 1. TẠO TÀI KHOẢN KHÁCH HÀNG + BIỂN SỐ ----------
  const insertUser = db.prepare("INSERT INTO users (username, name, password, balance) VALUES (?, ?, ?, ?)");
  const insertPlate = db.prepare("INSERT INTO plates (plate, user_id) VALUES (?, ?)");

  DEMO_CUSTOMERS.forEach((cust) => {
    const hashed = bcrypt.hashSync(cust.password, 10);
    insertUser.run(cust.username, cust.name, hashed, cust.balance, function (err) {
      if (err) return console.error("Lỗi tạo KH:", err.message);
      const userId = this.lastID;
      cust.plates.forEach((plate) => {
        insertPlate.run(plate, userId, (err2) => {
          if (err2) console.error("Lỗi gán biển số:", err2.message);
        });
      });
      console.log(`✅ Khách hàng: ${cust.username} / mật khẩu: ${cust.password} (${cust.name}) - Số dư: ${cust.balance.toLocaleString()}đ - Biển số: ${cust.plates.join(", ")}`);
    });
  });
  insertUser.finalize();
  insertPlate.finalize();

  // ---------- 2. TẠO LƯỢT GỬI XE (LỊCH SỬ + XE ĐANG TRONG BÃI) ----------
  setTimeout(() => {
    const insertCar = db.prepare(`
      INSERT INTO cars (uid, plate, time_in, time_out, fee, payment_method, payment_status, paid_at, active)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);

    // 2a. Xe ĐANG TRONG BÃI (active=1) - tối đa 4 xe (MAX_CARS=4), để bãi không đầy hẳn cho dễ test
    const activePlates = ["51A12345", "30A99999", "29A88888"];
    activePlates.forEach((plate, i) => {
      const timeIn = daysAgoMs(0, 7 + i); // vào từ sáng nay
      insertCar.run(`UID_DEMO_${i + 1}`, plate, timeIn, null, null, "", "PENDING", null, 1);
    });
    console.log(`✅ Đã tạo ${activePlates.length} xe đang trong bãi (active)`);

    // 2b. Lượt gửi xe ĐÃ HOÀN TẤT trong 60 ngày qua - để có dữ liệu Thống kê hôm nay, Lịch sử, Doanh thu
    let completedCount = 0;
    for (let d = 0; d < 60; d++) {
      // Không phải ngày nào cũng có xe - random 0-3 lượt/ngày cho thực tế
      const tripsToday = d === 0 ? randInt(1, 3) : randInt(0, 3);
      for (let t = 0; t < tripsToday; t++) {
        const plate = SAMPLE_PLATES[randInt(0, SAMPLE_PLATES.length - 1)];
        const hourIn = randInt(6, 20);
        const timeIn = daysAgoMs(d, hourIn);
        const durationHours = randInt(1, 6);
        const timeOut = timeIn + durationHours * 3600 * 1000;
        // Khớp CHÍNH XÁC công thức calculateFee() trong server.js: BASE_FEE=3000, HOURLY_RATE=2000
        // hours <= 1 -> chỉ tính BASE_FEE; hours > 1 -> BASE_FEE + (hours-1)*HOURLY_RATE
        const fee = durationHours <= 1 ? 3000 : 3000 + (durationHours - 1) * 2000;
        const paymentMethod = Math.random() > 0.4 ? "WALLET" : "CASH";

        insertCar.run(
          `UID_DEMO_H${d}_${t}`,
          plate,
          timeIn,
          timeOut,
          fee,
          paymentMethod,
          "PAID",
          timeOut,
          0
        );
        completedCount++;
      }
    }
    insertCar.finalize(() => {
      console.log(`✅ Đã tạo ${completedCount} lượt gửi xe đã hoàn tất (60 ngày qua)`);
    });

    // ---------- 3. TẠO LỊCH SỬ BIẾN ĐỘNG VÍ (nạp tiền + trừ phí) - để test biểu đồ chi tiêu ----------
    db.all("SELECT id, username FROM users", [], (err, users) => {
      if (err || !users) return;
      const insertTx = db.prepare("INSERT INTO wallet_transactions (user_id, amount, type, description, timestamp) VALUES (?, ?, ?, ?, ?)");

      users.forEach((u) => {
        // Vài lượt nạp tiền rải rác trong 5 tháng qua
        const topupCount = randInt(2, 5);
        for (let i = 0; i < topupCount; i++) {
          const daysBack = randInt(0, 150);
          const amount = [50000, 100000, 200000, 500000][randInt(0, 3)];
          insertTx.run(u.id, amount, "TOPUP", "Nạp tiền vào ví", sqliteTimestampDaysAgo(daysBack));
        }
        // Vài lượt trừ phí gửi xe rải rác
        const feeCount = randInt(3, 8);
        for (let i = 0; i < feeCount; i++) {
          const daysBack = randInt(0, 150);
          const amount = -(3000 + randInt(1, 6) * 2000);
          insertTx.run(u.id, amount, "PARKING_FEE", "Thanh toán phí gửi xe", sqliteTimestampDaysAgo(daysBack));
        }
      });

      insertTx.finalize(() => {
        console.log(`✅ Đã tạo lịch sử biến động ví cho ${users.length} khách hàng`);
        console.log("\n🎉 HOÀN TẤT NẠP DỮ LIỆU DEMO!");
        console.log("=".repeat(50));
        console.log("Tài khoản khách hàng để đăng nhập thử (App Khách hàng):");
        DEMO_CUSTOMERS.forEach((c) => console.log(`  - ${c.username} / ${c.password}`));
        console.log("\nTài khoản nhân viên để đăng nhập thử (App Nhân viên):");
        console.log("  - NV1 / 1    - NV2 / 2    - NV3 / 3");
        console.log("=".repeat(50));
        db.close();
      });
    });
  }, 500); // đợi 500ms để đảm bảo users/plates đã insert xong trước khi insert cars phụ thuộc plate
});
