**Smart Parking System**

Đồ án tốt nghiệp: Xây dựng bãi đỗ xe thông minh sử dụng AI nhận diện biển số và thẻ NFC ảo trên điện thoại.

**Giới thiệu**
Đây là hệ thống bãi đỗ xe thông minh cho phép nhân viên sử dụng điện thoại Android để nhận diện biển số xe bằng AI và xác thực khách hàng bằng thẻ NFC ảo. Hệ thống giao tiếp với máy chủ thông qua MQTT và điều khiển barie bằng ESP32.
Mục tiêu của dự án là giảm chi phí triển khai so với mô hình sử dụng camera IP và máy tính xử lý AI truyền thống.

**Kiến trúc hệ thống**
Hệ thống gồm ba thành phần chính:
  Mobile App (Flutter): Chụp biển số, nhận diện bằng Google ML Kit, quét NFC.
  Backend (Node.js): Xử lý dữ liệu, quản lý cơ sở dữ liệu và giao tiếp MQTT.
  IoT (ESP32): Điều khiển barie và LCD.

**Công nghệ và công cụ phát triển**
  Flutter
  Google ML Kit
  
  HCE NFC
  
  Node.js
  
  SQLite
  
  MQTT (HiveMQ Cloud Broker)
  
  ESP32

**Chức năng chính**
Nhân viên
  1.Đăng nhập hệ thống.
  2.Quét biển số bằng AI.
  3.Quét thẻ NFC ảo.
  4.Ghi nhận xe vào.
  5.Xử lý xe ra và xác nhận thu tiền mặt khi cần.
  6.Mở barie theo kết quả xác thực.

Quản trị viên
  1.Quản lý người dùng.
  2.Quản lý khách hàng và phương tiện.
  3.Theo dõi xe đang gửi.
  4.Xem lịch sử vào ra.
  5.Thống kê doanh thu.
  6.Ghi nhận mở barie thủ công.

**Cấu trúc thư mục**
SmartParking/
  ├── ParkGate/                      # Flutter App khách hàng
  ├── parking_app/                   # Flutter App nhân viên
  ├── MaiCode/server.js/             # Node.js Server
  ├── BaiDauXe/BaiDauXe.ino          # ESP32 Firmware
  ├── MaiCode/parking.db             # Database & Scripts
  ├── 22050038_DoAnTotNghiep/        # Bản đồ án tốt nghiệp
  └── README.md

**Quy trình hoạt động**
Xe vào
  1.Nhân viên mở ứng dụng Flutter.
  2.Chụp biển số.
  3.Google ML Kit nhận diện biển số.
  4.Quét NFC.
  5.Dữ liệu gửi MQTT.
  6.Server lưu thông tin.
  7.ESP32 mở barie.

Xe ra
  1.Quét biển số.
  2.Quét NFC.
  3.Server đối chiếu dữ liệu.
  4.Tính phí gửi xe.
  5.Thanh toán ví hoặc xác nhận thu tiền mặt.
  6.ESP32 mở barie.
  7.Lưu lịch sử giao dịch.
