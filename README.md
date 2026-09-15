# Smart Parking System

> **Đồ án tốt nghiệp:** Xây dựng hệ thống bãi đỗ xe thông minh sử dụng AI nhận diện biển số và thẻ NFC ảo trên điện thoại.

---

## 📖 Giới thiệu

Đây là hệ thống bãi đỗ xe thông minh cho phép nhân viên sử dụng điện thoại Android để nhận diện biển số xe bằng AI và xác thực khách hàng bằng thẻ NFC ảo. Hệ thống giao tiếp với máy chủ thông qua **MQTT** và điều khiển barie bằng **ESP32**.

Mục tiêu của dự án là giảm chi phí triển khai so với mô hình sử dụng camera IP và máy tính xử lý AI truyền thống.

---

## Kiến trúc hệ thống

Hệ thống gồm ba thành phần chính:

- **Mobile App (Flutter):** Chụp biển số, nhận diện bằng Google ML Kit và quét NFC.
- **Backend (Node.js):** Xử lý dữ liệu, quản lý cơ sở dữ liệu và giao tiếp MQTT.
- **IoT (ESP32):** Điều khiển barie và màn hình LCD.

---

## Công nghệ và công cụ phát triển

| Thành phần | Công nghệ |
|------------|-----------|
| Mobile | Flutter |
| AI | Google ML Kit |
| NFC | HCE (Host Card Emulation) |
| Backend | Node.js |
| Database | SQLite |
| MQTT | HiveMQ Cloud Broker |
| IoT | ESP32 |

---

## Chức năng chính

### Nhân viên

- Đăng nhập hệ thống.
- Quét biển số bằng AI.
- Quét thẻ NFC ảo.
- Ghi nhận xe vào.
- Xử lý xe ra và xác nhận thu tiền mặt khi cần.
- Mở barie theo kết quả xác thực.

### Quản trị viên

- Quản lý người dùng.
- Quản lý khách hàng và phương tiện.
- Theo dõi xe đang gửi.
- Xem lịch sử vào ra.
- Thống kê doanh thu.
- Ghi nhận mở barie thủ công.

---

## Cấu trúc thư mục

```text
SmartParking/
├── ParkGate/                    # Flutter App khách hàng
├── parking_app/                 # Flutter App nhân viên
├── MaiCode/
│   ├── server.js                # Node.js Server
│   └── parking.db               # SQLite Database
├── BaiDauXe/
│   └── BaiDauXe.ino             # ESP32 Firmware
├── 22050038_DoAnTotNghiep/      # Báo cáo đồ án tốt nghiệp
└── README.md
```

---

## Quy trình hoạt động

### Xe vào

1. Nhân viên mở ứng dụng Flutter.
2. Chụp biển số xe.
3. Google ML Kit nhận diện biển số.
4. Quét thẻ NFC ảo.
5. Dữ liệu được gửi đến Server qua MQTT.
6. Server lưu thông tin vào cơ sở dữ liệu.
7. ESP32 mở barie.

### Xe ra

1. Quét biển số xe.
2. Quét thẻ NFC ảo.
3. Server đối chiếu thông tin.
4. Tính phí gửi xe.
5. Thanh toán bằng ví hoặc xác nhận thu tiền mặt.
6. ESP32 mở barie.
7. Lưu lịch sử giao dịch.
