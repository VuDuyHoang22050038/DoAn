// ==========================================================
// APP KHÁCH HÀNG - Smart Parking (Customer App)
// ==========================================================
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ==========================================
// CẤU HÌNH SERVER
// Có thể tự chỉnh IP ngay trong App (nút Cài đặt ở màn hình Đăng nhập) - lưu lại qua SharedPreferences
// nên không cần build lại app mỗi khi IP máy chủ đổi. Giá trị mặc định ban đầu (khi chưa từng lưu IP nào)
// lấy từ --dart-define lúc build, ví dụ:
//   flutter run --dart-define=SERVER_HOST=192.168.1.43 --dart-define=SERVER_PORT=5000
// ==========================================
const String kDefaultServerHost = String.fromEnvironment('SERVER_HOST', defaultValue: '192.168.1.43');
const int kServerPort = int.fromEnvironment('SERVER_PORT', defaultValue: 5000);
const String kPrefsServerHostKey = 'server_ip';

String kServerHost = kDefaultServerHost;
String get kApiBase => "http://$kServerHost:$kServerPort";

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  kServerHost = prefs.getString(kPrefsServerHostKey) ?? kDefaultServerHost;
  runApp(const CustomerApp());
}

// ---------- BẢNG MÀU ----------
class AppColors {
  static const primary = Color(0xFF0EA5E9);
  static const primaryDark = Color(0xFF0369A1);
  static const bgLight = Color(0xFFF0F9FF);
  static const bgDark = Color(0xFF0A192F);
  static const cardDark = Color(0xFF112240);
  static const border = Color(0xFFBAE6FD);
  static const success = Color(0xFF10B981);
  static const danger = Color(0xFFEF4444);
  static const warning = Color(0xFFF59E0B);
  static const textDim = Color(0xFF64748B);
}

// Định dạng số tiền kiểu Việt Nam: 1234567 -> "1.234.567đ"
String formatCurrency(dynamic amount) {
  if (amount == null) return "0đ";
  final n = amount is int ? amount : int.tryParse(amount.toString()) ?? 0;
  final s = n.toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write('.');
    buf.write(s[i]);
  }
  return "${buf.toString()}đ";
}

// Kiểm tra định dạng biển số xe Việt Nam cơ bản (VD: 51A12345, 29H1-23456)
bool isValidPlateFormat(String plate) {
  final cleaned = plate.trim().toUpperCase().replaceAll(RegExp(r'[\s\-.]'), '');
  return RegExp(r'^[0-9]{2}[A-Z]{1,2}[0-9]{4,6}$').hasMatch(cleaned);
}

class CustomerApp extends StatefulWidget {
  const CustomerApp({super.key});
  @override
  State<CustomerApp> createState() => _CustomerAppState();
}

class _CustomerAppState extends State<CustomerApp> {
  bool _isDarkMode = false;

  void _toggleTheme() => setState(() => _isDarkMode = !_isDarkMode);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Parking - Khách Hàng',
      debugShowCheckedModeBanner: false,
      theme: _isDarkMode
          ? ThemeData.dark().copyWith(
              scaffoldBackgroundColor: AppColors.bgDark,
              colorScheme: const ColorScheme.dark(
                primary: AppColors.primary,
                secondary: AppColors.success,
              ),
            )
          : ThemeData.light().copyWith(
              scaffoldBackgroundColor: AppColors.bgLight,
              colorScheme: const ColorScheme.light(
                primary: AppColors.primary,
                secondary: AppColors.success,
                surface: Colors.white,
              ),
            ),
      home: SplashScreen(isDarkMode: _isDarkMode, onToggleTheme: _toggleTheme),
    );
  }
}

// ==========================================================
// SPLASH SCREEN - dựng hoàn toàn bằng widget (không cần file ảnh logo riêng)
// ==========================================================
class SplashScreen extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback onToggleTheme;
  const SplashScreen({super.key, required this.isDarkMode, required this.onToggleTheme});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    _scale = CurvedAnimation(parent: _controller, curve: Curves.elasticOut);
    _opacity = CurvedAnimation(parent: _controller, curve: const Interval(0, 0.5, curve: Curves.easeIn));
    _controller.forward();

    Timer(const Duration(milliseconds: 1800), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => LoginScreen(isDarkMode: widget.isDarkMode, onToggleTheme: widget.onToggleTheme),
      ));
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: widget.isDarkMode ? AppColors.bgDark : AppColors.bgLight,
      body: Center(
        child: FadeTransition(
          opacity: _opacity,
          child: ScaleTransition(
            scale: _scale,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [AppColors.primaryDark, AppColors.primary]),
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: AppColors.primary.withValues(alpha: 0.4), blurRadius: 24, spreadRadius: 4)],
                  ),
                  child: const Icon(Icons.local_parking, color: Colors.white, size: 52),
                ),
                const SizedBox(height: 20),
                Text(
                  "SMART PARKING",
                  style: TextStyle(
                    color: widget.isDarkMode ? Colors.white : const Color(0xFF0F172A),
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 6),
                const Text("Ứng dụng Khách hàng", style: TextStyle(color: AppColors.textDim, fontSize: 13)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ==========================================================
// MÀN HÌNH ĐĂNG NHẬP
// ==========================================================
class LoginScreen extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback onToggleTheme;
  const LoginScreen({super.key, required this.isDarkMode, required this.onToggleTheme});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _login() async {
    final username = _usernameCtrl.text.trim();
    if (username.isEmpty || _passCtrl.text.isEmpty) {
      setState(() => _error = "Vui lòng nhập Tên đăng nhập và Mật khẩu");
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final res = await http.post(
        Uri.parse('$kApiBase/api/customer/login'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          "username": username,
          "id": username,
          "password": _passCtrl.text
        }),
      );
      final decoded = json.decode(res.body);
      if (res.statusCode == 200 && decoded['success'] == true) {
        final data = decoded['data'];
        if (!mounted) return;
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => HomeScreen(
            customerId: data['username'] ?? data['id'] ?? username,
            customerName: data['name'] ?? username,
            initialBalance: data['balance'] ?? 0,
            isDarkMode: widget.isDarkMode,
            onToggleTheme: widget.onToggleTheme,
          ),
        ));
      } else {
        setState(() => _error = decoded['message'] ?? "Đăng nhập thất bại");
      }
    } catch (e) {
      setState(() => _error = "Không kết nối được máy chủ. Kiểm tra IP Server (nút Cài đặt trên góc phải).");
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // --- HỘP THOẠI QUÊN MẬT KHẨU (ĐÃ SỬA LỖI BUILDCONTEXT SYNCHRONOUSLY) ---
  Future<void> _showForgotPasswordDialog([String? initialUsername]) async {
    final forgotUsernameCtrl = TextEditingController(text: initialUsername ?? _usernameCtrl.text.trim());
    bool isSubmitting = false;
    String? dialogError;

    await showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (stfContext, setDialogState) {
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.lock_reset, color: AppColors.primary),
                SizedBox(width: 8),
                Text("Quên mật khẩu"),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Nhập Tên đăng nhập của bạn để gửi yêu cầu đặt lại mật khẩu tới Quản trị viên:",
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: forgotUsernameCtrl,
                  decoration: const InputDecoration(
                    labelText: "Tên đăng nhập",
                    prefixIcon: Icon(Icons.account_circle_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                if (dialogError != null) ...[
                  const SizedBox(height: 8),
                  Text(dialogError!, style: const TextStyle(color: AppColors.danger, fontSize: 12, fontWeight: FontWeight.bold)),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: isSubmitting ? null : () => Navigator.pop(dialogCtx),
                child: const Text("HỦY"),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white),
                onPressed: isSubmitting
                    ? null
                    : () async {
                        final un = forgotUsernameCtrl.text.trim();
                        if (un.isEmpty) {
                          setDialogState(() => dialogError = "Vui lòng nhập Tên đăng nhập");
                          return;
                        }
                        setDialogState(() { isSubmitting = true; dialogError = null; });
                        try {
                          final res = await http.post(
                            Uri.parse('$kApiBase/api/customer/forgot-password'),
                            headers: {'Content-Type': 'application/json'},
                            body: json.encode({"username": un, "id": un}),
                          );
                          final decoded = json.decode(res.body);
                          if (res.statusCode == 200 && decoded['success'] == true) {
                            if (!dialogCtx.mounted) return;
                            Navigator.pop(dialogCtx);
                            if (!mounted) return;
                            showDialog(
                              context: context,
                              builder: (successCtx) => AlertDialog(
                                title: const Text("Đã gửi yêu cầu!"),
                                content: Text(decoded['message'] ?? "Yêu cầu khôi phục mật khẩu đã được gửi đến Quản trị viên. Vui lòng đợi Admin xử lý."),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(successCtx),
                                    child: const Text("ĐỒNG Ý"),
                                  ),
                                ],
                              ),
                            );
                          } else {
                            setDialogState(() => dialogError = decoded['message'] ?? "Không tìm thấy tên đăng nhập này");
                          }
                        } catch (e) {
                          setDialogState(() => dialogError = "Không thể kết nối Server");
                        } finally {
                          setDialogState(() => isSubmitting = false);
                        }
                      },
                child: isSubmitting
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text("GỬI YÊU CẦU"),
              ),
            ],
          );
        },
      ),
    );
  }

  // --- CÀI ĐẶT IP MÁY CHỦ (có thể tự chỉnh, lưu lại qua SharedPreferences) ---
  Future<void> _showSettingsDialog() async {
    final ipCtrl = TextEditingController(text: kServerHost);
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Cài đặt máy chủ"),
        content: TextField(
          controller: ipCtrl,
          decoration: const InputDecoration(labelText: "Địa chỉ IP Server", hintText: "VD: 192.168.1.43", border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Hủy")),
          ElevatedButton(
            onPressed: () async {
              if (ipCtrl.text.trim().isNotEmpty) {
                setState(() => kServerHost = ipCtrl.text.trim());
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString(kPrefsServerHostKey, kServerHost);
                if (!mounted) return;
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Đã lưu IP: $kServerHost")));
              }
            },
            child: const Text("Lưu"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Đăng nhập"),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: "Cài đặt IP máy chủ",
            onPressed: _showSettingsDialog,
          ),
          IconButton(
            icon: Icon(widget.isDarkMode ? Icons.light_mode : Icons.dark_mode),
            onPressed: widget.onToggleTheme,
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.local_parking, size: 72, color: AppColors.primary),
              const SizedBox(height: 12),
              const Text("SMART PARKING", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 1)),
              const Text("Ứng dụng khách hàng", style: TextStyle(color: AppColors.textDim)),
              const SizedBox(height: 32),
              TextField(
                controller: _usernameCtrl,
                decoration: const InputDecoration(
                  labelText: "Tên đăng nhập",
                  prefixIcon: Icon(Icons.account_circle_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _passCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: "Mật khẩu",
                  prefixIcon: Icon(Icons.lock_outline),
                  border: OutlineInputBorder(),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => _showForgotPasswordDialog(),
                  child: const Text(
                    "Quên mật khẩu?",
                    style: TextStyle(fontStyle: FontStyle.italic),
                  ),
                ),
              ),
              if (_error != null) ...[
                Text(_error!, style: const TextStyle(color: AppColors.danger, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)),
                  onPressed: _loading ? null : _login,
                  child: _loading
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text("ĐĂNG NHẬP", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => RegisterScreen(
                    isDarkMode: widget.isDarkMode, 
                    onToggleTheme: widget.onToggleTheme,
                    onOpenForgotPassword: _showForgotPasswordDialog,
                  ),
                )),
                child: const Text("Chưa có tài khoản? Đăng ký ngay"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================================
// MÀN HÌNH ĐĂNG KÝ
// ==========================================================
class RegisterScreen extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback onToggleTheme;
  final Function(String?) onOpenForgotPassword;

  const RegisterScreen({
    super.key, 
    required this.isDarkMode, 
    required this.onToggleTheme,
    required this.onOpenForgotPassword,
  });

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _usernameCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _passConfirmCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _register() async {
    final username = _usernameCtrl.text.trim();
    final name = _nameCtrl.text.trim();
    
    if (username.isEmpty || name.isEmpty || _passCtrl.text.isEmpty) {
      setState(() => _error = "Vui lòng nhập đầy đủ thông tin");
      return;
    }
    if (_passCtrl.text != _passConfirmCtrl.text) {
      setState(() => _error = "Mật khẩu nhập lại không khớp");
      return;
    }
    
    setState(() { _loading = true; _error = null; });
    try {
      final res = await http.post(
        Uri.parse('$kApiBase/api/customer/register'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          "username": username,
          "id": username,
          "name": name, 
          "password": _passCtrl.text
        }),
      );
      final decoded = json.decode(res.body);
      if (res.statusCode == 200 && decoded['success'] == true) {
        if (!mounted) return;
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
            title: const Text("Đăng ký thành công!"),
            content: Text(
              "Tên đăng nhập của bạn là:\n\n$username\n\nHãy ghi nhớ Tên đăng nhập này để đăng nhập vào ứng dụng.",
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text("ĐÃ GHI NHỚ"),
              ),
            ],
          ),
        );
        if (!mounted) return;
        Navigator.of(context).pop();
      } else {
        setState(() => _error = decoded['message'] ?? "Tên đăng nhập đã tồn tại hoặc đăng ký thất bại");
      }
    } catch (e) {
      setState(() => _error = "Không kết nối được máy chủ.");
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Đăng ký tài khoản"), centerTitle: true),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            TextField(
              controller: _usernameCtrl,
              decoration: const InputDecoration(
                labelText: "Tên đăng nhập (Viết liền, không dấu)", 
                prefixIcon: Icon(Icons.account_circle_outlined), 
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: "Họ và tên", 
                prefixIcon: Icon(Icons.person_outline), 
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _passCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: "Mật khẩu", 
                prefixIcon: Icon(Icons.lock_outline), 
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _passConfirmCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: "Nhập lại mật khẩu", 
                prefixIcon: Icon(Icons.lock_outline), 
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: AppColors.danger, fontWeight: FontWeight.bold)),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.success, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)),
                onPressed: _loading ? null : _register,
                child: _loading
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text("ĐĂNG KÝ", style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () {
                final currentUsername = _usernameCtrl.text.trim();
                Navigator.pop(context);
                widget.onOpenForgotPassword(currentUsername.isNotEmpty ? currentUsername : null);
              },
              child: const Text(
                "Đã có tài khoản nhưng quên mật khẩu?",
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================================
// MÀN HÌNH THANH TOÁN NẠP VÍ (mô phỏng luồng thanh toán thật - DEMO, không qua cổng thanh toán thật)
// ==========================================================
class _PaymentMethod {
  final String name;
  final String subtitle;
  final IconData icon;
  final Color color;
  const _PaymentMethod(this.name, this.subtitle, this.icon, this.color);
}

const List<_PaymentMethod> _paymentMethods = [
  _PaymentMethod("Thẻ ATM / Napas", "Liên kết ngân hàng nội địa", Icons.credit_card, AppColors.primary),
  _PaymentMethod("Internet Banking", "Chuyển khoản qua ứng dụng ngân hàng", Icons.account_balance, Color(0xFF7C3AED)),
  _PaymentMethod("Ví MoMo", "Thanh toán qua ví điện tử MoMo", Icons.wallet, Color(0xFFD82D8B)),
  _PaymentMethod("Ví ZaloPay", "Thanh toán qua ví điện tử ZaloPay", Icons.account_balance_wallet, Color(0xFF0068FF)),
];

class TopupPaymentScreen extends StatefulWidget {
  final int amount;
  final bool isDarkMode;
  final Future<bool> Function(int amount) onConfirmTopup;
  const TopupPaymentScreen({super.key, required this.amount, required this.isDarkMode, required this.onConfirmTopup});

  @override
  State<TopupPaymentScreen> createState() => _TopupPaymentScreenState();
}

enum _PayStep { chooseMethod, processing, success, failed }

class _TopupPaymentScreenState extends State<TopupPaymentScreen> {
  int _selectedIndex = 0;
  _PayStep _step = _PayStep.chooseMethod;

  Color get _cCard => widget.isDarkMode ? AppColors.cardDark : Colors.white;
  Color get _cText => widget.isDarkMode ? Colors.white : const Color(0xFF0F172A);

  Future<void> _confirmPayment() async {
    setState(() => _step = _PayStep.processing);
    // Mô phỏng thời gian xử lý giao dịch như cổng thanh toán thật
    await Future.delayed(const Duration(milliseconds: 1600));
    final ok = await widget.onConfirmTopup(widget.amount);
    if (!mounted) return;
    setState(() => _step = ok ? _PayStep.success : _PayStep.failed);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Nạp tiền vào ví"),
        centerTitle: true,
        automaticallyImplyLeading: _step == _PayStep.chooseMethod,
      ),
      body: switch (_step) {
        _PayStep.chooseMethod => _buildChooseMethod(),
        _PayStep.processing => _buildProcessing(),
        _PayStep.success => _buildResult(success: true),
        _PayStep.failed => _buildResult(success: false),
      },
    );
  }

  Widget _buildChooseMethod() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
          child: Column(
            children: [
              const Text("SỐ TIỀN NẠP", style: TextStyle(fontSize: 11, color: AppColors.textDim, fontWeight: FontWeight.bold, letterSpacing: 1)),
              const SizedBox(height: 6),
              Text(formatCurrency(widget.amount), style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: _cText)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text("CHỌN PHƯƠNG THỨC THANH TOÁN", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.textDim)),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _paymentMethods.length,
            itemBuilder: (context, i) {
              final m = _paymentMethods[i];
              final selected = _selectedIndex == i;
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: _cCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: selected ? AppColors.primary : AppColors.border, width: selected ? 2 : 1),
                ),
                child: ListTile(
                  onTap: () => setState(() => _selectedIndex = i),
                  leading: Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(color: m.color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                    child: Icon(m.icon, color: m.color),
                  ),
                  title: Text(m.name, style: TextStyle(fontWeight: FontWeight.bold, color: _cText)),
                  subtitle: Text(m.subtitle, style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
                  trailing: Icon(
                    selected ? Icons.check_circle : Icons.circle_outlined,
                    color: selected ? AppColors.primary : AppColors.textDim,
                  ),
                ),
              );
            },
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 15)),
                onPressed: _confirmPayment,
                child: const Text("XÁC NHẬN THANH TOÁN", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProcessing() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 56, height: 56, child: CircularProgressIndicator(strokeWidth: 4, color: AppColors.primary)),
          const SizedBox(height: 20),
          Text("Đang xử lý giao dịch...", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: _cText)),
          const SizedBox(height: 6),
          const Text("Vui lòng không tắt ứng dụng", style: TextStyle(fontSize: 12, color: AppColors.textDim)),
        ],
      ),
    );
  }

  Widget _buildResult({required bool success}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: (success ? AppColors.success : AppColors.danger).withValues(alpha: 0.12), shape: BoxShape.circle),
              child: Icon(success ? Icons.check_circle : Icons.error_outline, color: success ? AppColors.success : AppColors.danger, size: 56),
            ),
            const SizedBox(height: 20),
            Text(
              success ? "Nạp tiền thành công!" : "Giao dịch thất bại",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: _cText),
            ),
            const SizedBox(height: 8),
            Text(
              success
                  ? "Đã cộng ${formatCurrency(widget.amount)} vào ví của bạn."
                  : "Không thể kết nối máy chủ. Vui lòng thử lại.",
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.textDim),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: success ? AppColors.success : AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () {
                  if (success) {
                    Navigator.of(context).pop(true);
                  } else {
                    setState(() => _step = _PayStep.chooseMethod);
                  }
                },
                child: Text(success ? "HOÀN TẤT" : "THỬ LẠI", style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================================
// MÀN HÌNH CHÍNH (sau khi đăng nhập)
// ==========================================================
class HomeScreen extends StatefulWidget {
  final dynamic customerId;
  final String customerName;
  final int initialBalance;
  final bool isDarkMode;
  final VoidCallback onToggleTheme;

  const HomeScreen({
    super.key,
    required this.customerId,
    required this.customerName,
    required this.initialBalance,
    required this.isDarkMode,
    required this.onToggleTheme,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tabIndex = 0;
  int _balance = 0;
  List<String> _plates = [];
  List<Map<String, dynamic>> _history = [];
  bool _loadingProfile = true;
  bool _loadingHistory = false;

  // Xem chỗ trống bãi xe ngay trên App (dữ liệu công khai, không cần đăng nhập)
  int? _availableSlots;
  int _maxCars = 4;
  bool _loadingParkingStatus = true;

  // Lịch sử ví (tách riêng khỏi lịch sử gửi xe) + toggle chọn xem loại nào
  List<Map<String, dynamic>> _walletHistory = [];
  bool _loadingWalletHistory = false;
  int _historyTabMode = 0; // 0 = lịch sử gửi xe, 1 = lịch sử ví

  @override
  void initState() {
    super.initState();
    _balance = widget.initialBalance;
    _loadProfile();
    _loadParkingStatus();
  }

  Color get _cCard => widget.isDarkMode ? AppColors.cardDark : Colors.white;
  Color get _cText => widget.isDarkMode ? Colors.white : const Color(0xFF0F172A);

  Future<void> _loadParkingStatus() async {
    setState(() => _loadingParkingStatus = true);
    try {
      final res = await http.get(Uri.parse('$kApiBase/api/parking-status')).timeout(const Duration(seconds: 6));
      final decoded = json.decode(res.body);
      if (decoded['success'] == true) {
        setState(() {
          _availableSlots = decoded['availableSlots'];
          _maxCars = decoded['maxCars'] ?? 4;
        });
      }
    } catch (e) {
      debugPrint("Lỗi tải trạng thái bãi xe: $e");
    } finally {
      if (mounted) setState(() => _loadingParkingStatus = false);
    }
  }

  Future<void> _loadProfile() async {
    setState(() => _loadingProfile = true);
    try {
      final res = await http.get(Uri.parse('$kApiBase/api/customer/${widget.customerId}'));
      final decoded = json.decode(res.body);
      if (decoded['success'] == true) {
        setState(() {
          _balance = decoded['data']['balance'];
          _plates = List<String>.from(decoded['data']['plates']);
        });
      }
    } catch (e) {
      debugPrint("Lỗi tải hồ sơ: $e");
    } finally {
      if (mounted) setState(() => _loadingProfile = false);
    }
  }

  Future<void> _loadHistory() async {
    setState(() => _loadingHistory = true);
    try {
      final res = await http.get(Uri.parse('$kApiBase/api/customer/${widget.customerId}/history'));
      final decoded = json.decode(res.body);
      if (decoded['success'] == true) {
        setState(() => _history = List<Map<String, dynamic>>.from(decoded['data']));
      }
    } catch (e) {
      debugPrint("Lỗi tải lịch sử: $e");
    } finally {
      if (mounted) setState(() => _loadingHistory = false);
    }
  }

  Future<void> _loadWalletHistory() async {
    setState(() => _loadingWalletHistory = true);
    try {
      final res = await http.get(Uri.parse('$kApiBase/api/customer/${widget.customerId}/wallet-history'));
      final decoded = json.decode(res.body);
      if (decoded['success'] == true) {
        setState(() => _walletHistory = List<Map<String, dynamic>>.from(decoded['data']));
      }
    } catch (e) {
      debugPrint("Lỗi tải lịch sử ví: $e");
    } finally {
      if (mounted) setState(() => _loadingWalletHistory = false);
    }
  }

  Future<void> _addPlate(String plate) async {
    try {
      final res = await http.post(
        Uri.parse('$kApiBase/api/customer/${widget.customerId}/plates'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({"plate": plate}),
      );
      final decoded = json.decode(res.body);
      if (!mounted) return;
      if (decoded['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Đã thêm biển số ${decoded['data']['plate']}"), backgroundColor: AppColors.success),
        );
        _loadProfile();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(decoded['message'] ?? "Thêm biển số thất bại"), backgroundColor: AppColors.danger),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Không kết nối được máy chủ"), backgroundColor: AppColors.danger),
      );
    }
  }

  Future<void> _deletePlate(String plate) async {
    try {
      final res = await http.delete(Uri.parse('$kApiBase/api/customer/${widget.customerId}/plates/$plate'));
      final decoded = json.decode(res.body);
      if (!mounted) return;
      if (decoded['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Đã gỡ biển số $plate"), backgroundColor: AppColors.success),
        );
        _loadProfile();
      }
    } catch (e) {
      debugPrint("Lỗi xóa biển số: $e");
    }
  }

  Future<bool> _topup(int amount) async {
    try {
      final res = await http.post(
        Uri.parse('$kApiBase/api/customer/${widget.customerId}/topup'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({"amount": amount}),
      );
      final decoded = json.decode(res.body);
      if (decoded['success'] == true) {
        if (mounted) setState(() => _balance = decoded['data']['balance']);
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  // Cài đặt IP ngay tại màn hình chính - phòng khi server đổi IP giữa lúc đang đăng nhập,
  // không cần đăng xuất mới sửa được.
  Future<void> _showSettingsDialog() async {
    final ipCtrl = TextEditingController(text: kServerHost);
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Cài đặt máy chủ"),
        content: TextField(
          controller: ipCtrl,
          decoration: const InputDecoration(labelText: "Địa chỉ IP Server", hintText: "VD: 192.168.1.43", border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Hủy")),
          ElevatedButton(
            onPressed: () async {
              if (ipCtrl.text.trim().isNotEmpty) {
                setState(() => kServerHost = ipCtrl.text.trim());
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString(kPrefsServerHostKey, kServerHost);
                if (!mounted) return;
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Đã lưu IP: $kServerHost")));
                _loadProfile();
                if (_tabIndex == 3) _loadHistory();
              }
            },
            child: const Text("Lưu"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      _buildHomeTab(),
      _buildPlatesTab(),
      _buildTopupTab(),
      _buildHistoryTab(),
      _buildAccountTab(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(_tabIndex == 4 ? "Tài khoản" : "Xin chào, ${widget.customerName}"),
        centerTitle: true,
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _loadProfile();
          await _loadParkingStatus();
          if (_tabIndex == 3) {
            if (_historyTabMode == 0) {
              await _loadHistory();
            } else {
              await _loadWalletHistory();
            }
          }
        },
        child: tabs[_tabIndex],
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed, // <--- Ép menu hiển thị cố định, tắt chế độ shifting
        backgroundColor: widget.isDarkMode ? AppColors.cardDark : Colors.white, // <--- Chỉnh màu nền theo giao diện sáng/tối
        unselectedItemColor: AppColors.textDim, // <--- Màu xám nhạt cho icon chưa chọn
        selectedItemColor: AppColors.primary, // <--- Màu xanh dương chủ đạo cho icon đang chọn
        currentIndex: _tabIndex,
        onTap: (i) {
          setState(() => _tabIndex = i);
          if (i == 3) {
            if (_historyTabMode == 0 && _history.isEmpty) _loadHistory();
            if (_historyTabMode == 1 && _walletHistory.isEmpty) _loadWalletHistory();
          }
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard_outlined), label: "Trang chủ"),
          BottomNavigationBarItem(icon: Icon(Icons.directions_car_outlined), label: "Biển số"),
          BottomNavigationBarItem(icon: Icon(Icons.account_balance_wallet_outlined), label: "Nạp ví"),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: "Lịch sử"),
          BottomNavigationBarItem(icon: Icon(Icons.person_outline), label: "Tài khoản"),
        ],
      ),
    );
  }

  // ---------- TAB 5: TÀI KHOẢN / CÀI ĐẶT ----------
  Widget _buildAccountTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border)),
          child: Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: AppColors.primary,
                child: Text(
                  widget.customerName.isNotEmpty ? widget.customerName.substring(0, 1).toUpperCase() : "?",
                  style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.customerName, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _cText)),
                    const SizedBox(height: 2),
                    Text("@${widget.customerId}", style: const TextStyle(color: AppColors.textDim, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const Text("TÙY CHỈNH", style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textDim, fontSize: 12)),
        const SizedBox(height: 8),
        _accountCard(
          children: [
            SwitchListTile(
              value: widget.isDarkMode,
              onChanged: (_) => widget.onToggleTheme(),
              activeThumbColor: AppColors.primary,
              secondary: const Icon(Icons.dark_mode_outlined, color: AppColors.primary),
              title: Text("Chế độ tối", style: TextStyle(color: _cText, fontWeight: FontWeight.w600)),
              subtitle: const Text("Bật/tắt giao diện tối cho ứng dụng", style: TextStyle(fontSize: 12)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.dns_outlined, color: AppColors.primary),
              title: Text("Kết nối máy chủ", style: TextStyle(color: _cText, fontWeight: FontWeight.w600)),
              subtitle: Text("Địa chỉ: $kServerHost:$kServerPort", style: const TextStyle(fontSize: 12)),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showSettingsDialog,
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Text("HỖ TRỢ", style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textDim, fontSize: 12)),
        const SizedBox(height: 8),
        _accountCard(
          children: [
            ListTile(
              leading: const Icon(Icons.lock_reset, color: AppColors.primary),
              title: Text("Đổi / khôi phục mật khẩu", style: TextStyle(color: _cText, fontWeight: FontWeight.w600)),
              subtitle: const Text("Gửi yêu cầu tới Quản trị viên", style: TextStyle(fontSize: 12)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text("Đổi mật khẩu"),
                  content: const Text("Vui lòng đăng xuất và chọn \"Quên mật khẩu?\" ở màn hình đăng nhập để gửi yêu cầu đặt lại mật khẩu tới Quản trị viên."),
                  actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("ĐÃ HIỂU"))],
                ),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.info_outline, color: AppColors.primary),
              title: Text("Về ứng dụng", style: TextStyle(color: _cText, fontWeight: FontWeight.w600)),
              subtitle: const Text("Smart Parking - Phiên bản 1.0.0", style: TextStyle(fontSize: 12)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showAboutDialog(
                context: context,
                applicationName: "Smart Parking",
                applicationVersion: "1.0.0",
                applicationIcon: const Icon(Icons.local_parking, color: AppColors.primary, size: 36),
                children: const [Text("Ứng dụng quản lý gửi xe thông minh dành cho khách hàng.")],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger, side: const BorderSide(color: AppColors.danger), padding: const EdgeInsets.symmetric(vertical: 13)),
            onPressed: () => showDialog(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text("Đăng xuất?"),
                content: const Text("Bạn có chắc muốn đăng xuất khỏi tài khoản này?"),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text("HỦY")),
                  TextButton(
                    onPressed: () => Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => LoginScreen(isDarkMode: widget.isDarkMode, onToggleTheme: widget.onToggleTheme)),
                    ),
                    child: const Text("ĐĂNG XUẤT", style: TextStyle(color: AppColors.danger)),
                  ),
                ],
              ),
            ),
            icon: const Icon(Icons.logout, size: 18),
            label: const Text("ĐĂNG XUẤT", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }

  Widget _accountCard({required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }

  // ---------- TAB 1: TRANG CHỦ ----------
  Widget _buildHomeTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Thẻ số dư kiểu thẻ ngân hàng: chip, số thẻ ẩn, số dư, nút nạp nhanh
        Container(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [AppColors.primaryDark, AppColors.primary, Color(0xFF38BDF8)], begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [BoxShadow(color: AppColors.primary.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 8))],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(8)),
                    child: const Icon(Icons.credit_card, color: Colors.white, size: 20),
                  ),
                  const Text("SMART PARKING", style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 1.5)),
                ],
              ),
              const SizedBox(height: 20),
              const Text("SỐ DƯ KHẢ DỤNG", style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600, fontSize: 11, letterSpacing: 1)),
              const SizedBox(height: 6),
              _loadingProfile
                  ? const SizedBox(height: 34, width: 34, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3))
                  : Text(formatCurrency(_balance), style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: 0.5)),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("CHỦ THẺ", style: TextStyle(color: Colors.white54, fontSize: 9, letterSpacing: 1)),
                      Text(widget.customerName.toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white54),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    ),
                    onPressed: () => setState(() => _tabIndex = 2),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text("Nạp tiền", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        // Xem chỗ trống bãi xe ngay trên App - dữ liệu công khai, kéo xuống để làm mới
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(color: AppColors.success.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.local_parking, color: AppColors.success),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Tình trạng bãi xe", style: TextStyle(color: _cText, fontWeight: FontWeight.w600, fontSize: 13)),
                    const SizedBox(height: 2),
                    _loadingParkingStatus
                        ? const Text("Đang tải...", style: TextStyle(fontSize: 12, color: AppColors.textDim))
                        : Text(
                            _availableSlots == null ? "Không có dữ liệu" : "Còn trống $_availableSlots/$_maxCars chỗ",
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: (_availableSlots ?? 1) <= 0
                                  ? AppColors.danger
                                  : (_availableSlots ?? 4) <= 1
                                      ? AppColors.warning
                                      : AppColors.success,
                            ),
                          ),
                  ],
                ),
              ),
              IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _loadParkingStatus, color: AppColors.textDim),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Text("BIỂN SỐ ĐÃ ĐĂNG KÝ (${_plates.length})", style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.textDim, fontSize: 12)),
        const SizedBox(height: 10),
        if (_plates.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
            child: Column(
              children: [
                const Icon(Icons.info_outline, color: AppColors.textDim),
                const SizedBox(height: 8),
                const Text("Bạn chưa đăng ký biển số nào.", textAlign: TextAlign.center),
                TextButton(onPressed: () => setState(() => _tabIndex = 1), child: const Text("Thêm biển số ngay")),
              ],
            ),
          )
        else
          ..._plates.map((p) => Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
                child: Row(
                  children: [
                    const Icon(Icons.directions_car, color: AppColors.primary),
                    const SizedBox(width: 10),
                    Text(p, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 1, color: _cText)),
                  ],
                ),
              )),
      ],
    );
  }

  // ---------- TAB 2: QUẢN LÝ BIỂN SỐ ----------
  Widget _buildPlatesTab() {
    final plateCtrl = TextEditingController();
    String? fieldError;
    return StatefulBuilder(
      builder: (context, setLocalState) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Thêm biển số mới", style: TextStyle(fontWeight: FontWeight.bold, color: _cText, fontSize: 15)),
                const SizedBox(height: 4),
                const Text("Nhập biển số xe của bạn, không dấu cách, không dấu gạch ngang.", style: TextStyle(fontSize: 12, color: AppColors.textDim)),
                const SizedBox(height: 12),
                TextField(
                  controller: plateCtrl,
                  textCapitalization: TextCapitalization.characters,
                  onChanged: (_) {
                    if (fieldError != null) setLocalState(() => fieldError = null);
                  },
                  decoration: InputDecoration(
                    labelText: "Biển số xe",
                    prefixIcon: const Icon(Icons.directions_car_outlined),
                    border: const OutlineInputBorder(),
                    isDense: true,
                    errorText: fieldError,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: AppColors.success, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 13)),
                    onPressed: () {
                      final raw = plateCtrl.text.trim().toUpperCase();
                      if (raw.isEmpty) {
                        setLocalState(() => fieldError = "Vui lòng nhập biển số");
                        return;
                      }
                      if (!isValidPlateFormat(raw)) {
                        setLocalState(() => fieldError = "Biển số không đúng định dạng (VD: 51A12345)");
                        return;
                      }
                      showDialog(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text("Xác nhận thêm biển số"),
                          content: Text("Bạn có chắc muốn thêm biển số \"$raw\" vào tài khoản?"),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context), child: const Text("HỦY")),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(backgroundColor: AppColors.success, foregroundColor: Colors.white),
                              onPressed: () {
                                Navigator.pop(context);
                                _addPlate(raw);
                                plateCtrl.clear();
                              },
                              child: const Text("XÁC NHẬN"),
                            ),
                          ],
                        ),
                      );
                    },
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text("THÊM BIỂN SỐ", style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          if (_plates.isNotEmpty) Text("DANH SÁCH BIỂN SỐ (${_plates.length})", style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.textDim, fontSize: 12)),
          if (_plates.isNotEmpty) const SizedBox(height: 10),
          ..._plates.map((p) => Card(
                color: _cCard,
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: AppColors.border)),
                child: ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                    child: const Icon(Icons.directions_car, color: AppColors.primary),
                  ),
                  title: Text(p, style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1, color: _cText)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: AppColors.danger),
                    onPressed: () => showDialog(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text("Gỡ biển số?"),
                        content: Text("Bạn có chắc muốn gỡ biển số $p khỏi tài khoản?"),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context), child: const Text("HỦY")),
                          TextButton(
                            onPressed: () { Navigator.pop(context); _deletePlate(p); },
                            child: const Text("GỠ", style: TextStyle(color: AppColors.danger)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              )),
        ],
      ),
    );
  }

  // ---------- TAB 3: NẠP VÍ ----------
  void _goToPayment(int amount) async {
    if (amount <= 0) return;
    final result = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => TopupPaymentScreen(
        amount: amount,
        isDarkMode: widget.isDarkMode,
        onConfirmTopup: _topup,
      ),
    ));
    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Đã nạp ${formatCurrency(amount)} vào ví"), backgroundColor: AppColors.success),
      );
    }
  }

  Widget _buildTopupTab() {
    final amountCtrl = TextEditingController();
    const quickAmounts = [50000, 100000, 200000, 500000];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [AppColors.primaryDark, AppColors.primary], begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              const Icon(Icons.account_balance_wallet, color: Colors.white, size: 30),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Số dư hiện tại", style: TextStyle(color: Colors.white70, fontSize: 12)),
                    Text(formatCurrency(_balance), style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text("SỐ TIỀN NHANH", style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textDim, fontSize: 12)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: quickAmounts.map((amt) => ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: _cCard, foregroundColor: AppColors.primary, side: const BorderSide(color: AppColors.border), elevation: 0),
                onPressed: () => _goToPayment(amt),
                child: Text("+${formatCurrency(amt)}"),
              )).toList(),
        ),
        const SizedBox(height: 20),
        const Text("SỐ TIỀN KHÁC", style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textDim, fontSize: 12)),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: amountCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: "Nhập số tiền (VNĐ)", border: OutlineInputBorder(), isDense: true),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white),
              onPressed: () {
                final amt = int.tryParse(amountCtrl.text.trim());
                if (amt != null && amt > 0) _goToPayment(amt);
              },
              child: const Text("TIẾP TỤC"),
            ),
          ],
        ),
      ],
    );
  }

  // ---------- TAB 4: LỊCH SỬ ----------
  Widget _buildHistoryTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Container(
            decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border)),
            padding: const EdgeInsets.all(4),
            child: Row(
              children: [
                Expanded(
                  child: _historyToggleButton("Gửi xe", 0, Icons.local_parking),
                ),
                Expanded(
                  child: _historyToggleButton("Biến động ví", 1, Icons.account_balance_wallet),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: _historyTabMode == 0 ? _buildParkingHistoryList() : _buildWalletHistoryList(),
        ),
      ],
    );
  }

  Widget _historyToggleButton(String label, int mode, IconData icon) {
    final selected = _historyTabMode == mode;
    return GestureDetector(
      onTap: () {
        setState(() => _historyTabMode = mode);
        if (mode == 0 && _history.isEmpty) _loadHistory();
        if (mode == 1 && _walletHistory.isEmpty) _loadWalletHistory();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(color: selected ? AppColors.primary : Colors.transparent, borderRadius: BorderRadius.circular(8)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: selected ? Colors.white : AppColors.textDim),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: selected ? Colors.white : AppColors.textDim)),
          ],
        ),
      ),
    );
  }

  Widget _buildParkingHistoryList() {
    if (_loadingHistory) return const Center(child: CircularProgressIndicator());
    if (_history.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.inbox_outlined, size: 48, color: AppColors.textDim),
            const SizedBox(height: 8),
            const Text("Chưa có lượt gửi xe nào."),
            TextButton(onPressed: _loadHistory, child: const Text("Tải lại")),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _history.length,
      itemBuilder: (context, i) {
        final item = _history[i];
        final bool active = item['active'] == 1;
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _cCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 6, offset: const Offset(0, 2))],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (active ? AppColors.success : AppColors.primary).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(active ? Icons.local_parking : Icons.check_circle_outline, color: active ? AppColors.success : AppColors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(item['plate'] ?? '--', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, letterSpacing: 1, color: _cText)),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                          decoration: BoxDecoration(
                            color: active ? AppColors.success.withValues(alpha: 0.15) : AppColors.textDim.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(active ? "TRONG BÃI" : "ĐÃ RA", style: TextStyle(color: active ? AppColors.success : AppColors.textDim, fontWeight: FontWeight.bold, fontSize: 10)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.login, size: 13, color: AppColors.textDim.withValues(alpha: 0.7)),
                        const SizedBox(width: 4),
                        Text(_formatTime(item['entry_time']), style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
                        const SizedBox(width: 14),
                        Icon(Icons.logout, size: 13, color: AppColors.textDim.withValues(alpha: 0.7)),
                        const SizedBox(width: 4),
                        Text(_formatTime(item['exit_time']), style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
                      ],
                    ),
                    if (item['fee'] != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(formatCurrency(item['fee']), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: _cText)),
                          if (item['payment_method'] != null)
                            Text(item['payment_method'], style: const TextStyle(fontSize: 11, color: AppColors.textDim, fontStyle: FontStyle.italic)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Lịch sử biến động ví + biểu đồ chi tiêu theo tháng (tự vẽ bằng widget, không cần thêm thư viện)
  Widget _buildWalletHistoryList() {
    if (_loadingWalletHistory) return const Center(child: CircularProgressIndicator());
    if (_walletHistory.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.receipt_long_outlined, size: 48, color: AppColors.textDim),
            const SizedBox(height: 8),
            const Text("Chưa có biến động ví nào."),
            TextButton(onPressed: _loadWalletHistory, child: const Text("Tải lại")),
          ],
        ),
      );
    }

    final monthlySpending = _computeMonthlySpending(_walletHistory);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (monthlySpending.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("CHI TIÊU 6 THÁNG GẦN ĐÂY", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.textDim, letterSpacing: 0.5)),
                const SizedBox(height: 16),
                SizedBox(height: 120, child: _buildBarChart(monthlySpending)),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
        Text("CHI TIẾT GIAO DỊCH (${_walletHistory.length})", style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.textDim, fontSize: 12)),
        const SizedBox(height: 10),
        ..._walletHistory.map((tx) {
          final int amount = tx['amount'] is int ? tx['amount'] : int.tryParse(tx['amount'].toString()) ?? 0;
          final bool isCredit = amount > 0;
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(color: (isCredit ? AppColors.success : AppColors.danger).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                  child: Icon(isCredit ? Icons.add : Icons.remove, color: isCredit ? AppColors.success : AppColors.danger, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tx['description'] ?? (tx['type'] ?? ''), style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: _cText)),
                      const SizedBox(height: 2),
                      Text(_formatDateTime(tx['timestamp']), style: const TextStyle(fontSize: 11, color: AppColors.textDim)),
                    ],
                  ),
                ),
                Text(
                  "${isCredit ? '+' : ''}${formatCurrency(amount)}",
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: isCredit ? AppColors.success : AppColors.danger),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  // Gom chi tiêu (chỉ tính khoản trừ tiền, amount < 0) theo từng tháng, trả về danh sách tối đa 6 tháng gần nhất
  List<MapEntry<String, int>> _computeMonthlySpending(List<Map<String, dynamic>> txs) {
    final Map<String, int> byMonth = {};
    for (final tx in txs) {
      final int amount = tx['amount'] is int ? tx['amount'] : int.tryParse(tx['amount'].toString()) ?? 0;
      if (amount >= 0) continue; // chỉ tính khoản chi (âm)
      final tsRaw = tx['timestamp'];
      DateTime? dt;
      if (tsRaw is String) dt = DateTime.tryParse(tsRaw);
      if (dt == null) continue;
      final key = "${dt.year}-${dt.month.toString().padLeft(2, '0')}";
      byMonth[key] = (byMonth[key] ?? 0) + amount.abs();
    }
    final entries = byMonth.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return entries.length > 6 ? entries.sublist(entries.length - 6) : entries;
  }

  Widget _buildBarChart(List<MapEntry<String, int>> data) {
    final maxVal = data.map((e) => e.value).fold<int>(0, (a, b) => a > b ? a : b);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: data.map((e) {
        final double heightRatio = maxVal == 0 ? 0 : e.value / maxVal;
        final parts = e.key.split('-');
        final monthLabel = "T${int.parse(parts[1])}";
        return Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(e.value > 0 ? "${(e.value / 1000).round()}k" : "", style: const TextStyle(fontSize: 9, color: AppColors.textDim)),
            const SizedBox(height: 4),
            Container(
              width: 24,
              height: 70 * heightRatio + 4,
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
              ),
            ),
            const SizedBox(height: 6),
            Text(monthLabel, style: const TextStyle(fontSize: 10, color: AppColors.textDim, fontWeight: FontWeight.bold)),
          ],
        );
      }).toList(),
    );
  }

  String _formatDateTime(dynamic raw) {
    if (raw == null) return "--";
    DateTime? d;
    if (raw is String) d = DateTime.tryParse(raw);
    if (d == null) return "--";
    return "${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')} ${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}";
  }

  String _formatTime(dynamic ts) {
    if (ts == null) return "--";
    final ms = ts is int ? ts : int.tryParse(ts.toString());
    if (ms == null) return "--";
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return "${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')} ${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}";
  }
}