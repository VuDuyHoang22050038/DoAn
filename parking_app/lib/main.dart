import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:nfc_manager/nfc_manager.dart';

List<CameraDescription> cameras = [];

// ==========================================
// CẤU HÌNH MQTT
// ==========================================
const String kMqttHost = String.fromEnvironment('MQTT_HOST', defaultValue: 'e7e61c7128e04eeda4a25b19da01382f.s1.eu.hivemq.cloud');
const int kMqttPort = int.fromEnvironment('MQTT_PORT', defaultValue: 8883);
const String kMqttUser = String.fromEnvironment('MQTT_USER', defaultValue: 'Hoang123');
const String kMqttPass = String.fromEnvironment('MQTT_PASS', defaultValue: 'Hoang123');

const String kTopicEntry = 'parking/entry';
const String kTopicManual = 'parking/manual';
const String kTopicEmployeeLogin = 'parking/employee_login';
const String kTopicShiftEnd = 'parking/shift_end';
const String kTopicShiftHistoryRequest = 'parking/shift_history_request';
const String kTopicExitConfirm = 'parking/exit_confirm';
const String kTopicLcd = 'parking/lcd';
const String kTopicSlots = 'parking/slots';
const String kTopicResponse = 'parking/response';
const String kTopicState = 'parking/state';

String generateRequestId(String prefix) {
  final now = DateTime.now();
  final datePart = "${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}";
  final timePart = "${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}";
  final rand = (1000 + (now.microsecondsSinceEpoch % 9000)).toString();
  return "$prefix-$datePart-$timePart-$rand";
}

final ValueNotifier<bool> guardThemeNotifier = ValueNotifier<bool>(true);
void toggleGuardTheme() {
  guardThemeNotifier.value = !guardThemeNotifier.value;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint("Lỗi khởi tạo camera: $e");
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: guardThemeNotifier,
      builder: (context, isDark, _) {
        return MaterialApp(
          title: 'Smart Parking Guard OS',
          theme: isDark
              ? ThemeData.dark().copyWith(
                  scaffoldBackgroundColor: const Color(0xFF0A192F),
                  colorScheme: const ColorScheme.dark(primary: Color(0xFF00D2FF), secondary: Color(0xFF64FFDA)),
                )
              : ThemeData.light().copyWith(
                  scaffoldBackgroundColor: const Color(0xFFF0F9FF),
                  colorScheme: const ColorScheme.light(primary: Color(0xFF0EA5E9), secondary: Color(0xFF10B981), surface: Colors.white),
                ),
          home: GuardSplashScreen(isDarkMode: isDark, onToggleTheme: toggleGuardTheme),
          debugShowCheckedModeBanner: false,
        );
      },
    );
  }
}

class GuardSplashScreen extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback onToggleTheme;
  const GuardSplashScreen({super.key, required this.isDarkMode, required this.onToggleTheme});

  @override
  State<GuardSplashScreen> createState() => _GuardSplashScreenState();
}

class _GuardSplashScreenState extends State<GuardSplashScreen> with SingleTickerProviderStateMixin {
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

    Timer(const Duration(milliseconds: 1600), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => EmployeeLoginScreen(isDarkMode: widget.isDarkMode, onToggleTheme: widget.onToggleTheme),
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
    final cBg = guardThemeNotifier.value ? const Color(0xFF0A192F) : const Color(0xFFF0F9FF);
    final cPrimary = guardThemeNotifier.value ? const Color(0xFF00D2FF) : const Color(0xFF0EA5E9);
    final cText = guardThemeNotifier.value ? Colors.white : const Color(0xFF0F172A);

    return Scaffold(
      backgroundColor: cBg,
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
                    gradient: LinearGradient(colors: [cPrimary.withValues(alpha: 0.7), cPrimary]),
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: cPrimary.withValues(alpha: 0.4), blurRadius: 24, spreadRadius: 4)],
                  ),
                  child: const Icon(Icons.local_parking, color: Colors.white, size: 52),
                ),
                const SizedBox(height: 20),
                Text("SMART PARKING", style: TextStyle(color: cText, fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 2)),
                const SizedBox(height: 6),
                const Text("Ứng dụng Nhân viên Bảo vệ", style: TextStyle(color: Colors.grey, fontSize: 13)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class EmployeeLoginScreen extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback onToggleTheme;
  const EmployeeLoginScreen({super.key, required this.isDarkMode, required this.onToggleTheme});

  @override
  State<EmployeeLoginScreen> createState() => _EmployeeLoginScreenState();
}

class _EmployeeLoginScreenState extends State<EmployeeLoginScreen> {
  final _idCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  MqttServerClient? _authClient;
  bool _loading = false;
  String? _error;
  bool _obscure = true;

  Color get _cBg => guardThemeNotifier.value ? const Color(0xFF0A192F) : const Color(0xFFF0F9FF);
  Color get _cCard => guardThemeNotifier.value ? const Color(0xFF112240) : Colors.white;
  Color get _cText => guardThemeNotifier.value ? Colors.white : const Color(0xFF0F172A);
  Color get _cPrimary => guardThemeNotifier.value ? const Color(0xFF00D2FF) : const Color(0xFF0EA5E9);

  @override
  void dispose() {
    _authClient?.disconnect();
    _idCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final empId = _idCtrl.text.trim();
    final pass = _passCtrl.text;
    if (empId.isEmpty || pass.isEmpty) {
      setState(() => _error = "Vui lòng nhập đầy đủ tài khoản và mật khẩu");
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final String clientId = 'guard_login_${DateTime.now().millisecondsSinceEpoch % 100000}';
      final client = MqttServerClient.withPort(kMqttHost, clientId, kMqttPort);
      client.useWebSocket = false;
      client.secure = true;
      client.onBadCertificate = (dynamic cert) => true;
      client.setProtocolV311();
      client.keepAlivePeriod = 20;
      client.connectionMessage = MqttConnectMessage().withClientIdentifier(clientId).authenticateAs(kMqttUser, kMqttPass).startClean();
      _authClient = client;

      await client.connect();
      final requestId = generateRequestId("LOGIN");
      final completer = Completer<Map<String, dynamic>?>();

      client.subscribe(kTopicResponse, MqttQos.atLeastOnce);
      client.updates!.listen((List<MqttReceivedMessage<MqttMessage?>>? c) {
        if (c == null || c.isEmpty || completer.isCompleted) return;
        final recMess = c[0].payload as MqttPublishMessage;
        final pt = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
        try {
          final data = json.decode(pt);
          if (data['requestId'] == requestId && data['event'] == 'employee_login') {
            completer.complete(data as Map<String, dynamic>);
          }
        } catch (_) {}
      });

      final builder = MqttClientPayloadBuilder();
      builder.addUTF8String(json.encode({"requestId": requestId, "employee_id": empId, "password": pass}));
      client.publishMessage(kTopicEmployeeLogin, MqttQos.atLeastOnce, builder.payload!);

      final result = await completer.future.timeout(const Duration(seconds: 8), onTimeout: () => null);
      client.disconnect();
      if (!mounted) return;

      if (result == null) {
        setState(() { _loading = false; _error = "Không nhận được phản hồi từ máy chủ. Kiểm tra kết nối mạng."; });
        return;
      }

      if (result['success'] == true) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => ParkingHomeScreen(
            isDarkMode: widget.isDarkMode,
            onToggleTheme: widget.onToggleTheme,
            employeeId: result['employee_id']?.toString() ?? empId,
            employeeName: result['name']?.toString() ?? empId,
          ),
        ));
      } else {
        setState(() { _loading = false; _error = result['msg']?.toString() ?? "Đăng nhập thất bại"; });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = "Không kết nối được máy chủ MQTT. Kiểm tra mạng và thử lại."; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: guardThemeNotifier,
      builder: (context, _, _) => Scaffold(
        backgroundColor: _cBg,
        appBar: AppBar(
          title: const Text("Đăng nhập Nhân viên"),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
          actions: [
            IconButton(icon: Icon(guardThemeNotifier.value ? Icons.light_mode : Icons.dark_mode), onPressed: toggleGuardTheme),
          ],
        ),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.local_parking, size: 64, color: _cPrimary),
                const SizedBox(height: 8),
                Text("SMART PARKING", style: TextStyle(color: _cText, fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
                const Text("Ứng dụng Nhân viên Bảo vệ", style: TextStyle(color: Colors.grey, fontSize: 13)),
                const SizedBox(height: 32),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(16), border: Border.all(color: _cPrimary.withValues(alpha: 0.2))),
                  child: Column(
                    children: [
                      TextField(
                        controller: _idCtrl,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(labelText: "Tài khoản nhân viên", prefixIcon: Icon(Icons.badge_outlined), border: OutlineInputBorder(), isDense: true),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _passCtrl,
                        obscureText: _obscure,
                        decoration: InputDecoration(
                          labelText: "Mật khẩu",
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        onSubmitted: (_) => _login(),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13), textAlign: TextAlign.center),
                      ],
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: _cPrimary, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
                          onPressed: _loading ? null : _login,
                          child: _loading
                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Text("ĐĂNG NHẬP", style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class GuardSettingsScreen extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback onToggleTheme;
  final String employeeId;
  final String employeeName;
  final bool embedded;
  const GuardSettingsScreen({
    super.key, required this.isDarkMode, required this.onToggleTheme,
    required this.employeeId, required this.employeeName, this.embedded = false,
  });

  @override
  State<GuardSettingsScreen> createState() => _GuardSettingsScreenState();
}

class _GuardSettingsScreenState extends State<GuardSettingsScreen> {
  Color get _cBg => guardThemeNotifier.value ? const Color(0xFF0A192F) : const Color(0xFFF0F9FF);
  Color get _cCard => guardThemeNotifier.value ? const Color(0xFF112240) : Colors.white;
  Color get _cBorder => guardThemeNotifier.value ? const Color(0xFF233554) : const Color(0xFFBAE6FD);
  Color get _cPrimary => guardThemeNotifier.value ? const Color(0xFF00D2FF) : const Color(0xFF0EA5E9);
  Color get _cMuted => guardThemeNotifier.value ? const Color(0xFF8892B0) : const Color(0xFF64748B);
  Color get _cText => guardThemeNotifier.value ? Colors.white : const Color(0xFF0F172A);

  bool _loadingShifts = false;
  List<Map<String, dynamic>> _shifts = [];
  String? _shiftError;

  Future<Map<String, dynamic>?> _sendMqttRequest(String topic, Map<String, dynamic> payload, String expectEvent) async {
    MqttServerClient? tempClient;
    try {
      final String clientId = 'guard_req_${DateTime.now().millisecondsSinceEpoch % 100000}';
      tempClient = MqttServerClient.withPort(kMqttHost, clientId, kMqttPort);
      tempClient.useWebSocket = false;
      tempClient.secure = true;
      tempClient.onBadCertificate = (dynamic cert) => true;
      tempClient.setProtocolV311();
      tempClient.keepAlivePeriod = 20;
      tempClient.connectionMessage = MqttConnectMessage().withClientIdentifier(clientId).authenticateAs(kMqttUser, kMqttPass).startClean();

      await tempClient.connect();
      final requestId = generateRequestId("REQ");
      final completer = Completer<Map<String, dynamic>?>();

      tempClient.subscribe(kTopicResponse, MqttQos.atLeastOnce);
      tempClient.updates!.listen((List<MqttReceivedMessage<MqttMessage?>>? c) {
        if (c == null || c.isEmpty || completer.isCompleted) return;
        final recMess = c[0].payload as MqttPublishMessage;
        final pt = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
        try {
          final data = json.decode(pt);
          if (data['requestId'] == requestId && data['event'] == expectEvent) {
            completer.complete(data as Map<String, dynamic>);
          }
        } catch (_) {}
      });

      final builder = MqttClientPayloadBuilder();
      builder.addUTF8String(json.encode({...payload, "requestId": requestId}));
      tempClient.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);

      return await completer.future.timeout(const Duration(seconds: 8), onTimeout: () => null);
    } catch (e) {
      return null;
    } finally {
      tempClient?.disconnect();
    }
  }

  Future<void> _loadShiftHistory() async {
    setState(() { _loadingShifts = true; _shiftError = null; });
    final result = await _sendMqttRequest(kTopicShiftHistoryRequest, {"employee_id": widget.employeeId}, "shift_history");
    if (!mounted) return;
    if (result == null) {
      setState(() { _loadingShifts = false; _shiftError = "Không nhận được phản hồi từ máy chủ."; });
      return;
    }
    if (result['success'] == true) {
      setState(() { _loadingShifts = false; _shifts = List<Map<String, dynamic>>.from(result['shifts'] ?? []); });
    } else {
      setState(() { _loadingShifts = false; _shiftError = result['msg']?.toString() ?? "Lỗi tải lịch sử ca làm việc"; });
    }
  }

  String _fmtTime(dynamic ms) {
    if (ms == null) return "--";
    final v = ms is int ? ms : int.tryParse(ms.toString());
    if (v == null) return "--";
    final d = DateTime.fromMillisecondsSinceEpoch(v);
    return "${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')} ${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}";
  }

  String _fmtMoney(dynamic n) {
    final v = n is int ? n : int.tryParse(n.toString()) ?? 0;
    final s = v.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write('.');
      buf.write(s[i]);
    }
    return "${buf.toString()}đ";
  }

  @override
  void initState() { super.initState(); _loadShiftHistory(); }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: guardThemeNotifier,
      builder: (context, _, _) {
        final content = ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(16), border: Border.all(color: _cBorder)),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: _cPrimary,
                    child: Text(
                      widget.employeeName.isNotEmpty ? widget.employeeName.substring(0, 1).toUpperCase() : "?",
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.employeeName, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _cText)),
                        const SizedBox(height: 2),
                        Text("@${widget.employeeId}", style: TextStyle(color: _cMuted, fontSize: 13)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text("TÙY CHỈNH", style: TextStyle(fontWeight: FontWeight.bold, color: _cMuted, fontSize: 12)),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: _cBorder)),
              clipBehavior: Clip.antiAlias,
              child: SwitchListTile(
                value: guardThemeNotifier.value,
                onChanged: (_) => toggleGuardTheme(),
                activeThumbColor: _cPrimary,
                secondary: Icon(Icons.dark_mode_outlined, color: _cPrimary),
                title: Text("Chế độ tối", style: TextStyle(color: _cText, fontWeight: FontWeight.w600)),
                subtitle: const Text("Bật/tắt giao diện tối cho ứng dụng", style: TextStyle(fontSize: 12)),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("LỊCH SỬ CA LÀM VIỆC CỦA TÔI", style: TextStyle(fontWeight: FontWeight.bold, color: _cMuted, fontSize: 12)),
                IconButton(icon: Icon(Icons.refresh, size: 18, color: _cMuted), onPressed: _loadShiftHistory),
              ],
            ),
            const SizedBox(height: 4),
            if (_loadingShifts) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else if (_shiftError != null)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: _cBorder)),
                child: Column(
                  children: [
                    Text(_shiftError!, style: const TextStyle(color: Colors.redAccent, fontSize: 13), textAlign: TextAlign.center),
                    TextButton(onPressed: _loadShiftHistory, child: const Text("Thử lại")),
                  ],
                ),
              )
            else if (_shifts.isEmpty)
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: _cBorder)),
                child: Column(
                  children: [
                    Icon(Icons.history_toggle_off, color: _cMuted),
                    const SizedBox(height: 8),
                    Text("Chưa có ca làm việc nào được ghi nhận.", style: TextStyle(color: _cMuted), textAlign: TextAlign.center),
                  ],
                ),
              )
            else
              ..._shifts.map((s) => Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: _cBorder)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.timer_outlined, size: 15, color: _cPrimary),
                            const SizedBox(width: 6),
                            Text("${_fmtTime(s['start_time'])} → ${_fmtTime(s['end_time'])}", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _cText)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text("Vào: ${s['entry_count'] ?? 0} · Ra: ${s['exit_count'] ?? 0}", style: TextStyle(fontSize: 12, color: _cMuted)),
                            Text(_fmtMoney(s['revenue']), style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: _cText)),
                          ],
                        ),
                      ],
                    ),
                  )),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, side: const BorderSide(color: Colors.redAccent), padding: const EdgeInsets.symmetric(vertical: 13)),
                onPressed: () => showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text("Đăng xuất?"),
                    content: Text("Đăng xuất khỏi tài khoản ${widget.employeeId}?"),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context), child: const Text("HỦY")),
                      TextButton(
                        onPressed: () => Navigator.of(context).pushAndRemoveUntil(
                          MaterialPageRoute(builder: (_) => EmployeeLoginScreen(isDarkMode: widget.isDarkMode, onToggleTheme: widget.onToggleTheme)),
                          (route) => false,
                        ),
                        child: const Text("ĐĂNG XUẤT", style: TextStyle(color: Colors.redAccent)),
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
        if (widget.embedded) return content;
        return Scaffold(backgroundColor: _cBg, appBar: AppBar(title: const Text("Cài đặt"), centerTitle: true), body: content);
      },
    );
  }
}

class ParkingHomeScreen extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback onToggleTheme;
  final String employeeId;
  final String employeeName;
  const ParkingHomeScreen({
    super.key, required this.isDarkMode, required this.onToggleTheme,
    required this.employeeId, required this.employeeName,
  });
  @override
  State<ParkingHomeScreen> createState() => _ParkingHomeScreenState();
}

class _ParkingHomeScreenState extends State<ParkingHomeScreen> {
  int _currentTabIndex = 0;
  MqttServerClient? client;
  String connectionStatus = "Chưa kết nối MQTT";
  bool isLoading = false;

  String get _currentEmployeeId => widget.employeeId;

  int _parkedCars = 0;
  int _availableSlots = 4;
  bool _isParkingFull = false;
  bool get _isNearFull => _availableSlots == 1 && !_isParkingFull;
  bool _hasAlertedNearFull = false;
  final List<Map<String, dynamic>> _historyList = [];
  
  String _historySearchQuery = "";
  String _historyFilter = "ALL";

  DateTime? _shiftStartTime;
  int _shiftEntryCount = 0;
  int _shiftExitCount = 0;
  int _shiftRevenue = 0;
  bool get _isOnShift => _shiftStartTime != null;

  bool _isInScanFlow = false;
  String _flowType = "XE VÀO";
  int _currentStep = 1;

  final List<bool> _slotOccupied = [false, false, false, false];
  final List<Map<String, String>> _evidencePhotos = [];

  bool _isSubmitting = false;
  bool _isWaitingPaymentConfirm = false;
  String? _submissionError;
  Timer? _submitTimeoutTimer;

  int _pendingFee = 0;
  String? _entryRequestId;
  String? _cashConfirmRequestId;

  String _tempRecognizedPlate = "";
  String? _savedPlate;
  String? _savedRFID;
  String _nfcStatus = "Chưa kích hoạt NFC";
  bool _isNfcScanning = false;

  CameraController? _cameraController;
  final TextRecognizer _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
  Timer? _scanTimer;
  bool _isProcessing = false;
  bool _isFlashOn = false;

  bool get _isDarkMode => guardThemeNotifier.value;
  Color get _cBg => _isDarkMode ? const Color(0xFF0A192F) : const Color(0xFFF0F9FF);
  Color get _cCard => _isDarkMode ? const Color(0xFF112240) : Colors.white;
  Color get _cBorder => _isDarkMode ? const Color(0xFF233554) : const Color(0xFFBAE6FD);
  Color get _cPrimary => _isDarkMode ? const Color(0xFF00D2FF) : const Color(0xFF0EA5E9);
  Color get _cAccent => _isDarkMode ? const Color(0xFF64FFDA) : const Color(0xFF10B981);
  Color get _cMuted => _isDarkMode ? const Color(0xFF8892B0) : const Color(0xFF64748B);
  Color get _cText => _isDarkMode ? Colors.white : const Color(0xFF0F172A);

  final List<Map<String, dynamic>> _pendingQueue = [];
  Timer? _queueRetryTimer;

  @override
  void initState() {
    super.initState();
    _connectMQTT();
    _queueRetryTimer = Timer.periodic(const Duration(seconds: 10), (_) => _tryFlushQueue());
  }

  String _formatTimestamp(dynamic timestamp) {
    if (timestamp == null || timestamp == "") return "--";
    int? ms = timestamp is int ? timestamp : int.tryParse(timestamp.toString());
    if (ms == null) return "--";
    DateTime date = DateTime.fromMillisecondsSinceEpoch(ms);
    return "${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')} ${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}";
  }

  String _formatFee(dynamic fee) {
    if (fee == null || fee == "") return "--";
    return "${fee.toString()}đ";
  }

  bool _isMqttConnected() {
    return client != null && client!.connectionStatus != null && client!.connectionStatus!.state == MqttConnectionState.connected;
  }

  Future<bool> _ensureConnected() async {
    if (_isMqttConnected()) return true;
    await _connectMQTT();
    return _isMqttConnected();
  }

  void _checkNearFullAlert() {
    if (_isNearFull && !_hasAlertedNearFull) {
      _hasAlertedNearFull = true;
      SystemSound.play(SystemSoundType.alert);
      HapticFeedback.heavyImpact();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("⚠️ BÃI XE SẮP ĐẦY - Chỉ còn 1 chỗ trống!"), backgroundColor: Colors.orange, duration: Duration(seconds: 4)));
      }
    } else if (!_isNearFull) {
      _hasAlertedNearFull = false;
    }
  }

  Future<void> _connectMQTT() async {
    if (client != null) { client!.disconnect(); client = null; }
    setState(() { connectionStatus = "Đang kết nối MQTT..."; isLoading = true; });

    final String uniqueClientId = 'guard_app_${DateTime.now().millisecondsSinceEpoch % 1000}';
    client = MqttServerClient.withPort(kMqttHost, uniqueClientId, kMqttPort);
    client!.useWebSocket = false;
    client!.secure = true;
    client!.onBadCertificate = (dynamic cert) => true;
    client!.setProtocolV311();
    client!.keepAlivePeriod = 20;
    client!.autoReconnect = true;
    client!.connectionMessage = MqttConnectMessage().withClientIdentifier(uniqueClientId).authenticateAs(kMqttUser, kMqttPass).startClean();

    client!.onDisconnected = () {
      if (mounted) setState(() => connectionStatus = "Mất kết nối MQTT...");
    };

    client!.onConnected = () {
      if (mounted) setState(() { connectionStatus = "MQTT Online"; isLoading = false; });
      client!.subscribe(kTopicLcd, MqttQos.atMostOnce);
      client!.subscribe(kTopicSlots, MqttQos.atMostOnce);
      client!.subscribe(kTopicResponse, MqttQos.atLeastOnce);
      client!.subscribe(kTopicState, MqttQos.atLeastOnce);
      _publishMessage(kTopicManual, json.encode({"action": "status"}), qos: MqttQos.atLeastOnce);
      _tryFlushQueue();
    };

    try {
      await client!.connect();
      client!.updates!.listen((List<MqttReceivedMessage<MqttMessage?>>? c) {
        if (c == null || c.isEmpty) return;
        final recMess = c[0].payload as MqttPublishMessage;
        final String topic = c[0].topic;
        final pt = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);

        try {
          if (topic == kTopicLcd) {
            final data = json.decode(pt);
            if (mounted) {
              setState(() {
                if (data['count'] != null) {
                  _parkedCars = data['count'];
                }
                
                if (data['free'] != null) {
                  _availableSlots = data['free'];
                }
                
                if (data['full'] != null) {
                  _isParkingFull = data['full'] == true;
                } else if (data['is_full'] != null) {
                  _isParkingFull = data['is_full'] == true;
                }
              });
              _checkNearFullAlert();
            }
          } else if (topic == kTopicSlots) {
            final data = json.decode(pt);
            if (mounted) {
              setState(() {
                for (int i = 0; i < 4; i++) {
                  final v = data['slot${i + 1}'];
                  if (v != null) _slotOccupied[i] = (v == 1 || v == true);
                }
              });
            }
          } else if (topic == kTopicResponse) {
            final data = json.decode(pt);
            final String? respRequestId = data['requestId'] as String?;
            final bool success = data['success'] == true;
            final String msg = (data['msg'] ?? '').toString();
            final String? event = data['event'] as String?;
            if (data['fee'] != null) _pendingFee = data['fee'] is int ? data['fee'] : int.tryParse(data['fee'].toString()) ?? 0;

            final bool matchesEntry = _entryRequestId != null && respRequestId == _entryRequestId;
            final bool matchesCash = _cashConfirmRequestId != null && respRequestId == _cashConfirmRequestId;

            if (mounted && (matchesEntry || matchesCash || respRequestId == null)) {
              _handleServerResponse(success, msg, event);
            }
          } else if (topic == kTopicState) {
            final data = json.decode(pt);
            if (mounted) {
              setState(() {
                if (data['parkedCars'] != null) _parkedCars = data['parkedCars'];
                if (data['availableSlots'] != null) _availableSlots = data['availableSlots'];
                if (data['isFull'] != null) _isParkingFull = data['isFull'] == true;
                for (int i = 0; i < 4; i++) {
                  final v = data['slot${i + 1}'];
                  if (v != null) _slotOccupied[i] = v == true;
                }
                if (data['history'] is List) {
                  _historyList.clear();
                  for (final item in (data['history'] as List)) {
                    final map = item as Map<String, dynamic>;
                    _historyList.add({
                      "plate": map['plate'], "uid": map['uid'],
                      "time_in": map['entry_time'], "time_out": map['exit_time'],
                      "fee": map['fee'], "active": map['active'],
                    });
                  }
                }
              });
              _checkNearFullAlert();
            }
          }
        } catch (e) { debugPrint("Lỗi parse dữ liệu MQTT: $e"); }
      });
    } catch (e) {
      if (mounted) setState(() { connectionStatus = "Lỗi MQTT"; isLoading = false; });
      if (client != null) { client!.disconnect(); client = null; }
    }
  }

  void _handleServerResponse(bool success, String msg, String? event) {
    _submitTimeoutTimer?.cancel();
    _entryRequestId = null;
    _cashConfirmRequestId = null;

    if (success && event == "entry_success") {
      setState(() { _isSubmitting = false; _submissionError = null; if (_isOnShift) _shiftEntryCount++; });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✓ XÁC NHẬN XE VÀO THÀNH CÔNG'), backgroundColor: Colors.teal, duration: Duration(seconds: 3)));
      _exitScanFlow();
    } else if (success && event == "exit_cash_pending") {
      setState(() { _isSubmitting = false; _submissionError = null; _currentStep = 4; });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('⚠️ VÍ KHÔNG ĐỦ TIỀN! Vui lòng thu phí tiền mặt.'), backgroundColor: Colors.amber));
    } else if (success && (event == "exit_wallet" || event == "exit_cash_done")) {
      setState(() { _isSubmitting = false; _isWaitingPaymentConfirm = false; if (_isOnShift) { _shiftExitCount++; _shiftRevenue += _pendingFee; } });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✓ Thanh toán hoàn tất. Barrier đang mở.'), backgroundColor: Colors.teal));
      _exitScanFlow();
    } else {
      setState(() { _isSubmitting = false; _isWaitingPaymentConfirm = false; _submissionError = msg.isNotEmpty ? msg : "Giao dịch bị từ chối bởi hệ thống"; });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('❌ HỆ THỐNG TỪ CHỐI / LỖI: $msg'), backgroundColor: Colors.redAccent, duration: const Duration(seconds: 4)));
    }
  }

  void _sendCashPaidConfirm() {
    setState(() => _isWaitingPaymentConfirm = true);
    _cashConfirmRequestId ??= generateRequestId("PAY");
    final Map<String, dynamic> exitPayload = { "requestId": _cashConfirmRequestId, "plate": _savedPlate, "payment_status": "PAID", "employee": _currentEmployeeId };
    final bool sent = _publishMessage(kTopicExitConfirm, json.encode(exitPayload), qos: MqttQos.atLeastOnce);
    if (!sent) _queueMessage(kTopicExitConfirm, exitPayload);
    _submitTimeoutTimer = Timer(const Duration(seconds: 10), () {
      if (mounted && _isWaitingPaymentConfirm) setState(() { _isWaitingPaymentConfirm = false; _submissionError = "❌ Server chưa xác nhận. Không cho xe ra."; });
    });
  }

  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) return;
    try {
      _cameraController = CameraController(cameras[0], ResolutionPreset.medium, enableAudio: false);
      await _cameraController!.initialize();
      _isFlashOn = false;
      if (!mounted) return;
      setState(() {});
      _startAutoScan();
    } catch (e) {
      debugPrint("Lỗi khi khởi tạo camera: $e");
    }
  }

  void _toggleFlash() async {
    if (_cameraController == null) return;
    try {
      await _cameraController!.setFlashMode(!_isFlashOn ? FlashMode.torch : FlashMode.off);
      setState(() => _isFlashOn = !_isFlashOn);
    } catch (_) {}
  }

  Future<void> _captureEvidencePhoto(String plate, String type) async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    try {
      final XFile imageFile = await _cameraController!.takePicture();
      final dir = File(imageFile.path).parent.path;
      final destPath = '$dir/evidence_${type}_${plate}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(imageFile.path).copy(destPath);
      if (mounted) {
        setState(() {
          _evidencePhotos.insert(0, { "path": destPath, "plate": plate, "type": type, "time": DateTime.now().toIso8601String() });
          if (_evidencePhotos.length > 30) _evidencePhotos.removeLast();
        });
      }
    } catch (e) { debugPrint("Lỗi chụp ảnh minh chứng: $e"); }
  }

  void _startAutoScan() {
    _scanTimer = Timer.periodic(const Duration(milliseconds: 1000), (timer) async {
      if (!_isInScanFlow || _currentStep != 1 || _isProcessing || _cameraController == null || !_cameraController!.value.isInitialized) return;

      _isProcessing = true;
      try {
        final XFile imageFile = await _cameraController!.takePicture();
        final inputImage = InputImage.fromFilePath(imageFile.path);
        final RecognizedText recognizedText = await _textRecognizer.processImage(inputImage);
        _findPlate(recognizedText.text);
        
        // SỬA LỖI: Cần await việc xóa file để tránh block UI (Jank)
        try {
          await File(imageFile.path).delete();
        } catch (_) {}
      } catch (e) {
        debugPrint("Lỗi AI: $e");
      } finally {
        // Đảm bảo cờ luôn được hạ xuống
        _isProcessing = false;
      }
    });
  }

  void _findPlate(String text) {
    String cleanText = text.replaceAll(RegExp(r'[\s\-\.]'), '').toUpperCase();
    RegExp plateRegex = RegExp(r'[1-9][0-9][A-Z][0-9A-Z]?[0-9]{4,5}');
    final match = plateRegex.firstMatch(cleanText);
    if (match != null) setState(() => _tempRecognizedPlate = match.group(0)!);
  }

  Future<void> _startNFCReading() async {
    try {
      await NfcManager.instance.stopSession().catchError((_) {});
      // ignore: deprecated_member_use
      bool isAvailable = await NfcManager.instance.isAvailable();
      if (!isAvailable) {
        if (mounted) setState(() { _isNfcScanning = false; _nfcStatus = "Thiết bị không hỗ trợ NFC hoặc chưa bật!"; });
        return;
      }

      if (mounted) setState(() { _isNfcScanning = true; _nfcStatus = "ĐANG CHỜ THẺ: Chạm thẻ NFC/RFID vào mặt lưng..."; });

      NfcManager.instance.startSession(
        pollingOptions: {NfcPollingOption.iso14443, NfcPollingOption.iso15693},
        onDiscovered: (NfcTag tag) async {
          String? rfid = _extractUidFromTag(tag);
          await NfcManager.instance.stopSession().catchError((_) {});

          if (mounted) {
            if (rfid != null && rfid.isNotEmpty) {
              setState(() { _savedRFID = rfid; _isNfcScanning = false; _nfcStatus = "Đã nhận dạng thẻ: $rfid"; _currentStep = 3; });
            } else {
              setState(() { _isNfcScanning = false; _nfcStatus = "Thẻ không hợp lệ. Vui lòng thử lại!"; });
            }
          }
        },
      );
    } catch (e) {
      if (mounted) setState(() { _isNfcScanning = false; _nfcStatus = "Lỗi quét NFC: $e"; });
    }
  }

  String? _extractUidFromTag(NfcTag tag) {
    try {
      final dynamic looseTag = tag;
      final dynamic obj = looseTag.data;
      List<int>? identifier;

      if (obj != null) {
        try { identifier = List<int>.from(obj.nfca.identifier); } catch (_) {}
        if (identifier == null) { try { identifier = List<int>.from(obj.mifareClassic.identifier); } catch (_) {} }
        if (identifier == null) { try { identifier = List<int>.from(obj.mifareclassic.identifier); } catch (_) {} }
        if (identifier == null) { try { identifier = List<int>.from(obj.isoDep.identifier); } catch (_) {} }
        if (identifier == null) { try { identifier = List<int>.from(obj.isodep.identifier); } catch (_) {} }
        if (identifier == null) { try { identifier = List<int>.from(obj.ndef.identifier); } catch (_) {} }
        if (identifier == null) { try { identifier = List<int>.from(obj.identifier); } catch (_) {} }
        if (identifier == null) { try { identifier = List<int>.from(obj.id); } catch (_) {} }
        if (identifier == null) { try { identifier = List<int>.from(obj.uid); } catch (_) {} }
      }

      if (identifier != null && identifier.isNotEmpty) {
        return identifier.map((e) => e.toRadixString(16).padLeft(2, '0').toUpperCase()).join('');
      }
    } catch (e) { debugPrint("Lỗi extract UID: $e"); }
    return null;
  }

  void _stopNFCReading() {
    NfcManager.instance.stopSession().catchError((_) {});
    if (mounted) setState(() => _isNfcScanning = false);
  }

  bool _publishMessage(String topic, String message, {MqttQos qos = MqttQos.atMostOnce}) {
    if (!_isMqttConnected()) return false;
    try {
      final builder = MqttClientPayloadBuilder();
      builder.addUTF8String(message);
      client!.publishMessage(topic, qos, builder.payload!);
      return true;
    } catch (e) { debugPrint("Lỗi publish MQTT: $e"); return false; }
  }

  void _queueMessage(String topic, Map<String, dynamic> payload) {
    setState(() => _pendingQueue.add({ "topic": topic, "payload": payload, "ts": DateTime.now().millisecondsSinceEpoch }));
  }

  Future<void> _tryFlushQueue() async {
    if (_pendingQueue.isEmpty || !_isMqttConnected()) return;

    final List<Map<String, dynamic>> stillPending = [];
    final int total = _pendingQueue.length;
    for (final item in List<Map<String, dynamic>>.from(_pendingQueue)) {
      final String topic = item['topic'] as String;
      final Map<String, dynamic> payload = item['payload'] as Map<String, dynamic>;
      final MqttQos qos = payload.containsKey('requestId') ? MqttQos.atLeastOnce : MqttQos.atMostOnce;
      final bool ok = _publishMessage(topic, json.encode(payload), qos: qos);
      if (!ok) stillPending.add(item);
      await Future.delayed(const Duration(milliseconds: 200));
    }

    if (!mounted) return;
    setState(() { _pendingQueue..clear()..addAll(stillPending); });

    if (stillPending.isEmpty && total > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Đã tự động gửi lại $total dữ liệu lưu tạm khi mất mạng.'), backgroundColor: _cAccent));
    }
  }

  Future<void> _submitDataToSystem() async {
    if (_savedPlate == null || _savedRFID == null) return;
    setState(() { _isSubmitting = true; _submissionError = null; });

    final bool isEntry = _flowType == "XE VÀO";
    _entryRequestId ??= generateRequestId(isEntry ? "ENTRY" : "EXIT");

    if (!_isMqttConnected()) {
      setState(() => _submissionError = "Mất kết nối mạng! Đang tự động kết nối lại...");
      bool reconnected = await _ensureConnected();
      if (!mounted) return;

      if (!reconnected) {
        _queueMessage(kTopicEntry, { "requestId": _entryRequestId, "plate": _savedPlate, "uid": _savedRFID, "type": isEntry ? "in" : "out" });
        setState(() { _isSubmitting = false; _submissionError = null; });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Không có mạng: đã LƯU TẠM dữ liệu $_flowType. Vui lòng mở cổng thủ công.'), backgroundColor: Colors.amber[800], duration: const Duration(seconds: 5)));
        _exitScanFlow();
        return;
      }
      setState(() => _submissionError = null);
    }

    _publishMessage(kTopicEntry, json.encode({ "requestId": _entryRequestId, "plate": _savedPlate, "uid": _savedRFID, "type": isEntry ? "in" : "out" }), qos: MqttQos.atLeastOnce);
    _submitTimeoutTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _isSubmitting) setState(() { _isSubmitting = false; _submissionError = "Quá thời gian chờ phản hồi từ máy chủ! Vui lòng thử lại."; });
    });
  }

  void _manualBarrierAction(String action, String label) {
    final String reqId = generateRequestId("MANUAL");
    final Map<String, dynamic> payload = { "requestId": reqId, "action": action, "reason": "Thao tác từ App", "employee": _currentEmployeeId };
    final bool sent = _publishMessage(kTopicManual, json.encode(payload), qos: MqttQos.atLeastOnce);
    if (!sent) _queueMessage(kTopicManual, payload);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Đã gửi lệnh: $label"), backgroundColor: Colors.green));
  }

  void _exitScanFlow() {
    _scanTimer?.cancel();
    _submitTimeoutTimer?.cancel();
    _cameraController?.dispose();
    _cameraController = null;
    _stopNFCReading();
    if (mounted) {
      setState(() {
        _isInScanFlow = false;
        _currentStep = 1;
        _savedPlate = null;
        _savedRFID = null;
        _tempRecognizedPlate = "";
        _isSubmitting = false;
        _isWaitingPaymentConfirm = false;
        _submissionError = null;
        _pendingFee = 0;
        _entryRequestId = null;
        _cashConfirmRequestId = null;
      });
    }
  }

  void _refreshFromServer() {
    if (!_isMqttConnected()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Chưa kết nối MQTT, không thể tải lại."), backgroundColor: Colors.redAccent));
      return;
    }
    client!.unsubscribe(kTopicState);
    client!.subscribe(kTopicState, MqttQos.atLeastOnce);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Đang tải lại dữ liệu..."), backgroundColor: _cAccent));
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _submitTimeoutTimer?.cancel();
    _queueRetryTimer?.cancel();
    _cameraController?.dispose();
    _textRecognizer.close();
    client?.disconnect();
    _stopNFCReading();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: guardThemeNotifier,
      builder: (context, _, _) => Scaffold(
        backgroundColor: _cBg,
        appBar: AppBar(
          title: Text(_currentTabIndex == 3 ? "Cài đặt" : _currentTabIndex == 2 ? "Ảnh minh chứng" : 'Smart Parking - ${widget.employeeName}'),
          backgroundColor: _cCard,
          centerTitle: true,
          actions: [
            if (_pendingQueue.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: Colors.amber[800], borderRadius: BorderRadius.circular(20)),
                    child: Row(
                      children: [
                        const Icon(Icons.cloud_off, size: 14, color: Colors.white), const SizedBox(width: 4),
                        Text("Chờ gửi: ${_pendingQueue.length}", style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
              ),
            IconButton(icon: const Icon(Icons.refresh), tooltip: "Kết nối lại MQTT", onPressed: _connectMQTT),
          ],
        ),
        body: IndexedStack(
          index: _currentTabIndex,
          children: [
            _isInScanFlow ? _buildScanFlowScreen() : _buildDashboardScreen(),
            _buildSlotStatusScreen(),
            EvidencePhotoScreen(photos: _evidencePhotos, isDarkMode: _isDarkMode, embedded: true),
            GuardSettingsScreen(isDarkMode: widget.isDarkMode, onToggleTheme: widget.onToggleTheme, employeeId: widget.employeeId, employeeName: widget.employeeName, embedded: true),
          ],
        ),
        bottomNavigationBar: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          backgroundColor: _cCard,
          selectedItemColor: _cPrimary,
          unselectedItemColor: _cMuted,
          currentIndex: _currentTabIndex,
          onTap: (index) {
            if (_isInScanFlow) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Vui lòng hủy quy trình hiện tại trước khi chuyển Tab!"), backgroundColor: Colors.amber));
              return;
            }
            setState(() { _currentTabIndex = index; });
          },
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.dashboard), label: "Trang chủ"),
            BottomNavigationBarItem(icon: Icon(Icons.grid_view), label: "Vị trí bãi"),
            BottomNavigationBarItem(icon: Icon(Icons.photo_library_outlined), label: "Ảnh"),
            BottomNavigationBarItem(icon: Icon(Icons.settings_outlined), label: "Cài đặt"),
          ],
        ),
      ),
    );
  }

  void _startShift() {
    setState(() { _shiftStartTime = DateTime.now(); _shiftEntryCount = 0; _shiftExitCount = 0; _shiftRevenue = 0; });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Đã bắt đầu ca làm việc"), backgroundColor: Colors.green));
  }

  void _endShift() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _cCard,
        title: Text("Tổng kết ca làm việc", style: TextStyle(color: _cText, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildConfirmRow("Bắt đầu", _formatClock(_shiftStartTime!), _cText),
            _buildConfirmRow("Kết thúc", _formatClock(DateTime.now()), _cText),
            const Divider(),
            _buildConfirmRow("Xe vào", "$_shiftEntryCount", _cPrimary),
            _buildConfirmRow("Xe ra", "$_shiftExitCount", _cPrimary),
            _buildConfirmRow("Doanh thu ca", _formatMoney(_shiftRevenue), _cAccent),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("ĐÓNG")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            onPressed: () {
              Navigator.pop(context);
              final payload = {
                "requestId": generateRequestId("SHIFT"), "employee_id": widget.employeeId, "employee_name": widget.employeeName,
                "start_time": _shiftStartTime!.millisecondsSinceEpoch, "end_time": DateTime.now().millisecondsSinceEpoch,
                "entry_count": _shiftEntryCount, "exit_count": _shiftExitCount, "revenue": _shiftRevenue,
              };
              final bool sent = _publishMessage(kTopicShiftEnd, json.encode(payload), qos: MqttQos.atLeastOnce);
              if (!sent) _queueMessage(kTopicShiftEnd, payload);

              setState(() { _shiftStartTime = null; _shiftEntryCount = 0; _shiftExitCount = 0; _shiftRevenue = 0; });
            },
            child: const Text("KẾT THÚC CA"),
          ),
        ],
      ),
    );
  }

  Widget _shiftStat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: _cMuted, fontSize: 11)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(color: _cText, fontSize: 14, fontWeight: FontWeight.w900)),
      ],
    );
  }

  String _formatClock(DateTime dt) {
    return "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')} ${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}";
  }

  bool _isSameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  int get _todayRevenue {
    final now = DateTime.now(); int total = 0;
    for (final item in _historyList) {
      final feeRaw = item['fee']; final timeOutRaw = item['time_out'];
      if (feeRaw == null || timeOutRaw == null) continue;
      final ms = timeOutRaw is int ? timeOutRaw : int.tryParse(timeOutRaw.toString());
      if (ms == null) continue;
      if (_isSameDay(DateTime.fromMillisecondsSinceEpoch(ms), now)) total += feeRaw is int ? feeRaw : int.tryParse(feeRaw.toString()) ?? 0;
    }
    return total;
  }

  int get _todayEntryCount {
    final now = DateTime.now(); int count = 0;
    for (final item in _historyList) {
      final timeInRaw = item['time_in'];
      if (timeInRaw == null) continue;
      final ms = timeInRaw is int ? timeInRaw : int.tryParse(timeInRaw.toString());
      if (ms == null) continue;
      if (_isSameDay(DateTime.fromMillisecondsSinceEpoch(ms), now)) count++;
    }
    return count;
  }

  String _formatMoney(int amount) {
    final s = amount.toString(); final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write('.'); buf.write(s[i]);
    }
    return "${buf.toString()}đ";
  }

  Widget _buildDashboardScreen() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _isOnShift ? _cAccent.withValues(alpha: 0.12) : _cCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _isOnShift ? _cAccent : _cBorder, width: _isOnShift ? 2 : 1),
            ),
            child: _isOnShift
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(Icons.timer, color: _cAccent, size: 18), const SizedBox(width: 8),
                        Text("ĐANG TRONG CA (từ ${_formatClock(_shiftStartTime!)})", style: TextStyle(color: _cAccent, fontWeight: FontWeight.bold, fontSize: 12)),
                      ]),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(child: _shiftStat("Xe vào", "$_shiftEntryCount")), Expanded(child: _shiftStat("Xe ra", "$_shiftExitCount")), Expanded(child: _shiftStat("Thu được", _formatMoney(_shiftRevenue))),
                      ]),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, side: const BorderSide(color: Colors.redAccent)), onPressed: _endShift, icon: const Icon(Icons.stop_circle_outlined, size: 18), label: const Text("KẾT THÚC CA", style: TextStyle(fontWeight: FontWeight.bold))),
                      ),
                    ],
                  )
                : SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: _cPrimary, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12)), onPressed: _startShift, icon: const Icon(Icons.play_circle_outline), label: const Text("BẮT ĐẦU CA LÀM VIỆC", style: TextStyle(fontWeight: FontWeight.bold))),
                  ),
          ),
          if (_isNearFull)
            Container(
              margin: const EdgeInsets.only(bottom: 16), padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.2), border: Border.all(color: Colors.orange, width: 2), borderRadius: BorderRadius.circular(12)),
              child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.warning_amber, color: Colors.orange, size: 26), SizedBox(width: 10),
                Text("⚠️ BÃI XE SẮP ĐẦY (còn 1 chỗ)", style: TextStyle(color: Colors.orange, fontSize: 16, fontWeight: FontWeight.w900)),
              ]),
            ),
          if (_isParkingFull)
            Container(
              margin: const EdgeInsets.only(bottom: 16), padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(color: Colors.redAccent.withValues(alpha: 0.2), border: Border.all(color: Colors.redAccent, width: 2), borderRadius: BorderRadius.circular(12)),
              child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.warning, color: Colors.redAccent, size: 28), SizedBox(width: 10),
                Text("🔴 BÃI ĐÃ ĐẦY", style: TextStyle(color: Colors.redAccent, fontSize: 18, fontWeight: FontWeight.w900)),
              ]),
            ),
          Row(children: [ Expanded(child: _buildStatCard("XE ĐANG ĐẬU", "$_parkedCars xe", _cPrimary)), const SizedBox(width: 12), Expanded(child: _buildStatCard("CHỖ TRỐNG", "$_availableSlots/4", _cAccent)) ]),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: _cBorder)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [ Icon(Icons.bar_chart, color: _cPrimary, size: 18), const SizedBox(width: 8), Text("THỐNG KÊ HÔM NAY", style: TextStyle(color: _cMuted, fontWeight: FontWeight.bold, fontSize: 12)) ]),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ Text("Doanh thu", style: TextStyle(color: _cMuted, fontSize: 12)), const SizedBox(height: 4), Text(_formatMoney(_todayRevenue), style: TextStyle(color: _cAccent, fontSize: 20, fontWeight: FontWeight.w900)) ])),
                    Container(width: 1, height: 36, color: _cBorder), const SizedBox(width: 16),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ Text("Lượt xe vào", style: TextStyle(color: _cMuted, fontSize: 12)), const SizedBox(height: 4), Text("$_todayEntryCount xe", style: TextStyle(color: _cPrimary, fontSize: 20, fontWeight: FontWeight.w900)) ])),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text("QUY TRÌNH KIỂM SOÁT CỔNG (TỰ ĐỘNG AI/NFC)", style: TextStyle(color: _cMuted, fontWeight: FontWeight.bold, fontSize: 12)),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: _cAccent, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8), elevation: 3),
                  onPressed: () {
                    if (_isParkingFull) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("🔴 Bãi đã đầy. Không thể tiếp nhận xe mới."), backgroundColor: Colors.redAccent)); return; }
                    setState(() { _flowType = "XE VÀO"; _isInScanFlow = true; }); _initializeCamera();
                  },
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: const [ Icon(Icons.login, size: 24), SizedBox(width: 6), Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text('XE VÀO', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)))) ]),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8), elevation: 3),
                  onPressed: () { setState(() { _flowType = "XE RA"; _isInScanFlow = true; }); _initializeCamera(); },
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: const [ Icon(Icons.logout, size: 24), SizedBox(width: 6), Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text('XE RA', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)))) ]),
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Text("ĐIỀU KHIỂN BARRIER THỦ CÔNG", style: TextStyle(color: _cMuted, fontWeight: FontWeight.bold, fontSize: 12)),
          const SizedBox(height: 10),
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _manualBarrierAction("open", "MỞ TỰ ĐỘNG (5S)"),
              child: Container(
                width: double.infinity, padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: _cPrimary.withValues(alpha: 0.4), width: 1.4)),
                child: Row(
                  children: [
                    Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: _cPrimary.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)), child: Icon(Icons.bolt, color: _cPrimary, size: 22)),
                    const SizedBox(width: 14),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ Text("Mở tự động", style: TextStyle(color: _cText, fontWeight: FontWeight.bold, fontSize: 14)), Text("Tự đóng lại sau 5 giây", style: TextStyle(color: _cMuted, fontSize: 12)) ])),
                    Icon(Icons.chevron_right, color: _cMuted),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14), onTap: () => _manualBarrierAction("open_manual", "MỞ GIỮ CỔNG"),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 10), decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.orange.withValues(alpha: 0.5), width: 1.4)),
                      child: Column(children: [ Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.lock_open, color: Colors.orange, size: 20)), const SizedBox(height: 8), Text("Mở & giữ cổng", textAlign: TextAlign.center, style: TextStyle(color: _cText, fontWeight: FontWeight.bold, fontSize: 12)) ]),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14), onTap: () => _manualBarrierAction("close", "ĐÓNG KHẨN CẤP"),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 10), decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.redAccent.withValues(alpha: 0.5), width: 1.4)),
                      child: Column(children: [ Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.redAccent.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.dangerous_outlined, color: Colors.redAccent, size: 20)), const SizedBox(height: 8), Text("Đóng khẩn cấp", textAlign: TextAlign.center, style: TextStyle(color: _cText, fontWeight: FontWeight.bold, fontSize: 12)) ]),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(children: [ Icon(Icons.history, color: _cMuted, size: 18), const SizedBox(width: 8), Text("LỊCH SỬ XE RA VÀO", style: TextStyle(color: _cMuted, fontWeight: FontWeight.bold, fontSize: 12)) ]),
              IconButton(icon: const Icon(Icons.refresh, size: 18), onPressed: _refreshFromServer, tooltip: "Tải lại lịch sử")
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  onChanged: (val) => setState(() => _historySearchQuery = val.trim().toUpperCase()),
                  decoration: InputDecoration(hintText: "Tìm biển số xe...", prefixIcon: const Icon(Icons.search, size: 18), contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12), filled: true, fillColor: _cCard, border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: _cBorder))),
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _historyFilter, dropdownColor: _cCard, underline: const SizedBox(),
                items: const [ DropdownMenuItem(value: "ALL", child: Text("Tất cả", style: TextStyle(fontSize: 12))), DropdownMenuItem(value: "ACTIVE", child: Text("Trong bãi", style: TextStyle(fontSize: 12))), DropdownMenuItem(value: "INACTIVE", child: Text("Đã rời", style: TextStyle(fontSize: 12))) ],
                onChanged: (val) { if (val != null) setState(() => _historyFilter = val); },
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildHistoryListCard(),
        ],
      ),
    );
  }

  Widget _buildHistoryListCard() {
    final filteredList = _historyList.where((item) {
      final plate = (item['plate'] ?? "").toString().toUpperCase();
      final bool matchesSearch = _historySearchQuery.isEmpty || plate.contains(_historySearchQuery);
      final bool isActive = item['active'] == 1;
      if (!matchesSearch) return false;
      if (_historyFilter == "ACTIVE" && !isActive) return false;
      if (_historyFilter == "INACTIVE" && isActive) return false;
      return true;
    }).toList();

    if (filteredList.isEmpty) {
      return Container(padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(16), border: Border.all(color: _cBorder)), child: Center(child: Text("Không tìm thấy bản ghi phù hợp", style: TextStyle(color: _cMuted))));
    }

    return ListView.builder(
      shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), itemCount: filteredList.length,
      itemBuilder: (context, index) {
        final item = filteredList[index]; bool isActive = item['active'] == 1;
        return Card(
          color: _cCard, margin: const EdgeInsets.only(bottom: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: _cBorder)),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(item['plate'] ?? 'KX-XXXXX', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: _cText, letterSpacing: 1.2)),
                    Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: isActive ? _cAccent.withValues(alpha: 0.15) : _cMuted.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)), child: Text(isActive ? "ĐANG TRONG BÃI" : "ĐÃ RỜI BÃI", style: TextStyle(color: isActive ? _cAccent : _cMuted, fontSize: 12, fontWeight: FontWeight.bold))),
                  ],
                ),
                const SizedBox(height: 8),
                Text("Thanh toán: ${isActive ? 'Chưa phát sinh' : 'Đã thanh toán'}", style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                Divider(color: _cBorder, height: 24),
                Row(
                  children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ Row(children: [ Icon(Icons.login, size: 14, color: _cPrimary), const SizedBox(width: 6), Text("Giờ Vào", style: TextStyle(color: _cMuted, fontSize: 12)) ]), const SizedBox(height: 4), Text(_formatTimestamp(item['time_in']), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)) ])),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ Row(children: [ const Icon(Icons.logout, size: 14, color: Colors.redAccent), const SizedBox(width: 6), Text("Giờ Ra", style: TextStyle(color: _cMuted, fontSize: 12)) ]), const SizedBox(height: 4), Text(_formatTimestamp(item['time_out']), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)) ])),
                  ],
                ),
                if (!isActive) ...[
                  const SizedBox(height: 12),
                  Container(padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10), decoration: BoxDecoration(color: Colors.amber.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [ const Text("Phí Thu:", style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 12)), Text(_formatFee(item['fee']), style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.w900, fontSize: 14)) ]))
                ]
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatCard(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(16), border: Border.all(color: _cBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [ Text(label, style: TextStyle(color: _cMuted, fontSize: 11, fontWeight: FontWeight.bold)), const SizedBox(height: 8), Text(value, style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.w800)) ]),
    );
  }

  Widget _buildScanFlowScreen() {
    int totalSteps = _flowType == "XE VÀO" ? 3 : 4;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) { if (!didPop) _exitScanFlow(); },
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_isMqttConnected()) ...[
                Container(padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12), margin: const EdgeInsets.only(bottom: 12), decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.redAccent, width: 1)), child: const Row(children: [ Icon(Icons.wifi_off, color: Colors.redAccent, size: 18), SizedBox(width: 8), Expanded(child: Text("Mất kết nối mạng! Dữ liệu sẽ tự động gửi lại.", style: TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold))) ])),
              ],
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [ Text("QUY TRÌNH $_flowType", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _flowType == "XE VÀO" ? _cAccent : Colors.redAccent)), TextButton.icon(onPressed: _isSubmitting || _isWaitingPaymentConfirm ? null : _exitScanFlow, icon: const Icon(Icons.cancel, color: Colors.grey), label: const Text("Hủy quy trình", style: TextStyle(color: Colors.grey))) ]),
              const SizedBox(height: 10),
              Row(children: [ _buildStepBadge(1, "Biển AI", _currentStep >= 1), _buildStepDivider(), _buildStepBadge(2, "Thẻ NFC", _currentStep >= 2), _buildStepDivider(), _buildStepBadge(3, "Server", _currentStep >= 3), if (totalSteps == 4) ...[ _buildStepDivider(), _buildStepBadge(4, "Ví/Tiền", _currentStep >= 4) ] ]),
              const SizedBox(height: 20),
              if (_currentStep == 1) _buildStep1Camera(),
              if (_currentStep == 2) _buildStep2RFID(),
              if (_currentStep == 3) _buildStep3Confirmation(),
              if (_currentStep == 4) _buildStep4Payment(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStepBadge(int step, String label, bool isActive) {
    return Row(children: [ CircleAvatar(radius: 12, backgroundColor: isActive ? _cPrimary : Colors.grey, child: Text("$step", style: const TextStyle(fontSize: 12, color: Colors.black, fontWeight: FontWeight.bold))), const SizedBox(width: 6), Text(label, style: TextStyle(fontWeight: isActive ? FontWeight.bold : FontWeight.normal)) ]);
  }

  Widget _buildStepDivider() { return Expanded(child: Divider(color: _cBorder, indent: 8, endIndent: 8)); }

  Widget _buildStep1Camera() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [ const Text("BƯỚC 1: AI ĐỌC BIỂN SỐ", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)), IconButton(icon: Icon(_isFlashOn ? Icons.flash_on : Icons.flash_off, color: _isFlashOn ? Colors.amber : Colors.grey), onPressed: _toggleFlash) ]),
        const SizedBox(height: 5),
        Container(
          height: 280, decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(16), border: Border.all(color: _cPrimary, width: 2)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: _cameraController != null && _cameraController!.value.isInitialized
                ? Stack(fit: StackFit.expand, children: [ CameraPreview(_cameraController!), Center(child: Container(width: 240, height: 110, decoration: BoxDecoration(border: Border.all(color: _cAccent, width: 2), borderRadius: BorderRadius.circular(8)))) ])
                : const Center(child: CircularProgressIndicator()),
          ),
        ),
        const SizedBox(height: 15),
        Text(_tempRecognizedPlate.isEmpty ? "Đang quét tìm biển số..." : "AI ĐÃ NHẬN DẠNG: $_tempRecognizedPlate", textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _tempRecognizedPlate.isEmpty ? Colors.amber : _cAccent)),
        const SizedBox(height: 15),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: _cPrimary, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          onPressed: _tempRecognizedPlate.isEmpty ? null : () async {
            final String plateForPhoto = _tempRecognizedPlate;
            final String typeForPhoto = _flowType == "XE VÀO" ? "in" : "out";
            await _captureEvidencePhoto(plateForPhoto, typeForPhoto);
            setState(() { _savedPlate = _tempRecognizedPlate; _currentStep = 2; });
            _scanTimer?.cancel();
            _cameraController?.dispose(); _cameraController = null;
            _startNFCReading();
          },
          child: const Center(child: Text("XÁC NHẬN BIỂN SỐ -> SANG BƯỚC 2", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
        ),
      ],
    );
  }

  Widget _buildStep2RFID() {
    bool isError = _nfcStatus.contains("Lỗi") || _nfcStatus.contains("chưa bật") || _nfcStatus.contains("thất bại");
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("BƯỚC 2: QUÉT THẺ NFC / RFID", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 15),
        Container(
          padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: _cBorder)),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(children: [ Icon(Icons.directions_car, color: _cPrimary), const SizedBox(width: 10), Text("Biển số AI: $_savedPlate", style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)) ]),
              IconButton(icon: const Icon(Icons.refresh, size: 18), onPressed: () { _stopNFCReading(); setState(() => _currentStep = 1); _initializeCamera(); }, tooltip: "Quét lại biển số")
            ],
          ),
        ),
        const SizedBox(height: 30),
        Center(
          child: Column(
            children: [
              Stack(alignment: Alignment.center, children: [ Icon(Icons.contactless_outlined, size: 110, color: isError ? Colors.redAccent : (_isNfcScanning ? _cAccent : _cMuted)), if (_isNfcScanning) const SizedBox(width: 130, height: 130, child: CircularProgressIndicator(strokeWidth: 3)) ]),
              const SizedBox(height: 20),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Text(_nfcStatus, textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: isError ? Colors.redAccent : Colors.white))),
              const SizedBox(height: 30),
              ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: _cAccent, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20)), onPressed: _startNFCReading, icon: const Icon(Icons.nfc), label: const Text("BẮT ĐẦU QUÉT THẺ NFC", style: TextStyle(fontWeight: FontWeight.bold))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStep3Confirmation() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("BƯỚC 3: XÁC NHẬN & GỬI SERVER", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 15),
        Container(
          padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(16), border: Border.all(color: _submissionError != null ? Colors.redAccent : (_flowType == "XE VÀO" ? _cAccent : Colors.redAccent), width: 1.5)),
          child: Column(children: [ Text("XÁC NHẬN THÔNG TIN $_flowType", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.grey)), Divider(color: _cBorder, height: 24), _buildConfirmRow("BIỂN SỐ XE:", "$_savedPlate", _cPrimary), const SizedBox(height: 12), _buildConfirmRow("MÃ THẺ NFC/RFID:", "$_savedRFID", _cAccent) ]),
        ),
        const SizedBox(height: 20),
        if (_submissionError != null) ...[ Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.1), border: Border.all(color: Colors.redAccent, width: 1.5), borderRadius: BorderRadius.circular(12)), child: Row(children: [ const Icon(Icons.error_outline, color: Colors.redAccent, size: 26), const SizedBox(width: 10), Expanded(child: Text(_submissionError!, style: const TextStyle(color: Colors.white, fontSize: 13))) ])), const SizedBox(height: 20) ],
        if (_isSubmitting)
          Center(child: Padding(padding: const EdgeInsets.all(20.0), child: Column(children: [ CircularProgressIndicator(color: _cPrimary), const SizedBox(height: 12), Text("Đang gửi dữ liệu lên Server...", style: TextStyle(color: _cMuted, fontWeight: FontWeight.bold)) ])))
        else ...[
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _flowType == "XE VÀO" ? _cAccent : Colors.redAccent, foregroundColor: _flowType == "XE VÀO" ? Colors.black : Colors.white, padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            onPressed: _submitDataToSystem,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [ const Icon(Icons.cloud_upload, size: 22), const SizedBox(width: 8), Flexible(child: FittedBox(fit: BoxFit.scaleDown, child: Text("XÁC NHẬN & CHO $_flowType", style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)))) ]),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.amber, side: const BorderSide(color: Colors.amber), padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            onPressed: () { setState(() { _currentStep = 1; _savedPlate = null; _savedRFID = null; _tempRecognizedPlate = ""; _submissionError = null; }); _initializeCamera(); },
            child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [ Icon(Icons.refresh, size: 20), SizedBox(width: 8), Text("QUÉT LẠI TỪ BƯỚC 1", style: TextStyle(fontWeight: FontWeight.bold)) ]),
          ),
        ],
      ],
    );
  }

  Widget _buildStep4Payment() {
    return Container(
      padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.amber, width: 2)),
      child: Column(
        children: [
          const Text("⚠️ VÍ KHÔNG ĐỦ TIỀN", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.amber)), Divider(color: _cBorder, height: 30),
          const Text("Phí gửi xe:", style: TextStyle(color: Colors.grey, fontSize: 14)), const SizedBox(height: 8), Text("$_pendingFee VNĐ", style: TextStyle(fontSize: 36, fontWeight: FontWeight.w900, color: _cText)), const SizedBox(height: 10), const Text("Khách thanh toán: TIỀN MẶT", style: TextStyle(color: Colors.grey, fontSize: 14, fontWeight: FontWeight.bold)), const SizedBox(height: 30),
          if (_isWaitingPaymentConfirm) Column(children: const [ CircularProgressIndicator(color: Colors.amber), SizedBox(height: 12), Text("⏳ Đang xác nhận thanh toán...", style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)) ])
          else SizedBox(width: double.infinity, child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: Colors.greenAccent, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(vertical: 18)), onPressed: _sendCashPaidConfirm, icon: const Icon(Icons.payments, size: 24), label: const Text("ĐÃ THU TIỀN", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)))),
        ],
      ),
    );
  }

  Widget _buildSlotStatusScreen() {
    final int freeCount = _slotOccupied.where((occupied) => !occupied).length;
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("TRẠNG THÁI CHỖ ĐỖ (THEO CẢM BIẾN)", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _cPrimary)), const SizedBox(height: 6), const Text("Dữ liệu trực tiếp từ 4 cảm biến LM393 tại bãi xe.", style: TextStyle(color: Colors.grey, fontSize: 12)), const SizedBox(height: 12),
          Container(padding: const EdgeInsets.symmetric(vertical: 12), decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: _cBorder)), child: Center(child: Text("CÒN TRỐNG: $freeCount / 4 CHỖ", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _cAccent)))),
          const SizedBox(height: 20),
          Expanded(
            child: GridView.count(
              crossAxisCount: 2, crossAxisSpacing: 16, mainAxisSpacing: 16,
              children: List.generate(4, (i) {
                final bool occupied = _slotOccupied[i]; final Color color = occupied ? Colors.redAccent : _cAccent;
                return Container(decoration: BoxDecoration(color: _cCard, borderRadius: BorderRadius.circular(16), border: Border.all(color: color, width: 2)), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [ Icon(occupied ? Icons.local_parking : Icons.check_circle_outline, size: 44, color: color), const SizedBox(height: 10), Text("VỊ TRÍ ${i + 1}", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)), const SizedBox(height: 4), Text(occupied ? "CÓ XE" : "TRỐNG", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color)) ]));
              }),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildConfirmRow(String label, String value, Color valColor) {
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [ Text(label, style: const TextStyle(fontWeight: FontWeight.bold)), Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: valColor, letterSpacing: 1)) ]);
  }
}

class EvidencePhotoScreen extends StatelessWidget {
  final List<Map<String, String>> photos;
  final bool isDarkMode;
  final bool embedded;
  const EvidencePhotoScreen({super.key, required this.photos, required this.isDarkMode, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final cBg = isDarkMode ? const Color(0xFF0A192F) : const Color(0xFFF0F9FF);
    final cCard = isDarkMode ? const Color(0xFF112240) : Colors.white;
    final cText = isDarkMode ? Colors.white : const Color(0xFF0F172A);

    final content = photos.isEmpty
        ? const Center(child: Text("Chưa có ảnh nào được chụp trong phiên làm việc này."))
        : GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 0.85),
            itemCount: photos.length,
            itemBuilder: (context, i) {
              final p = photos[i]; final bool isIn = p['type'] == 'in';
              DateTime? t; try { t = DateTime.parse(p['time'] ?? ''); } catch (_) {}
              return Container(
                decoration: BoxDecoration(color: cCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: isIn ? Colors.teal : Colors.orange)),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    Expanded(
                      child: (p['path'] != null && File(p['path']!).existsSync())
                          ? Image.file(File(p['path']!), fit: BoxFit.cover, width: double.infinity)
                          : const Center(child: Icon(Icons.broken_image, color: Colors.grey)),
                    ),
                    Container(
                      width: double.infinity, padding: const EdgeInsets.all(8), color: (isIn ? Colors.teal : Colors.orange).withValues(alpha: 0.15),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p['plate'] ?? '--', style: TextStyle(fontWeight: FontWeight.w900, color: cText, fontSize: 13)),
                          Text("${isIn ? 'VÀO' : 'RA'} • ${t != null ? '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')} ${t.day}/${t.month}' : ''}", style: TextStyle(color: isIn ? Colors.teal : Colors.orange, fontSize: 10, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );

    if (embedded) return content;
    return Scaffold(backgroundColor: cBg, appBar: AppBar(title: const Text("Ảnh minh chứng Xe Vào/Ra"), centerTitle: true), body: content);
  }
}