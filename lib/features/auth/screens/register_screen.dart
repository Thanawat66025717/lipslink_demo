import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/services/phone_index_service.dart';
import '../../../shared/widgets/gradient_button.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _surnameCtrl = TextEditingController(); 
  final _emailCtrl = TextEditingController(); 
  final _phoneCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  
  bool _isLoading = false;
  String? _errorMessage;

  // 🟢 ตัวแปรสำหรับซ่อน/แสดงรหัสผ่านแยกช่อง
  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  @override
  void dispose() {
    for (final c in [_nameCtrl, _surnameCtrl, _emailCtrl, _phoneCtrl, _passwordCtrl, _confirmCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _isLoading = true; _errorMessage = null; });

    try {
      String email = _emailCtrl.text.trim();
      String phone = _phoneCtrl.text.trim();

      // เช็กก่อนสร้างบัญชี ไม่งั้นจะได้บัญชี Auth ค้างที่ผูกเบอร์ไม่ได้
      if (await PhoneIndexService.isTakenByOther(phone, null)) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _errorMessage = 'เบอร์โทรศัพท์นี้มีผู้ใช้งานแล้ว';
          });
        }
        return;
      }

      // 1. สร้างบัญชีบน Firebase Auth
      UserCredential userCredential = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email,
        password: _passwordCtrl.text,
      );

      // 2. อัปเดตชื่อ-สกุลใน Auth
      String fullName = '${_nameCtrl.text.trim()} ${_surnameCtrl.text.trim()}';
      await userCredential.user?.updateDisplayName(fullName);
      
      // 3. บันทึกข้อมูลลง Firestore (ใช้ UID เป็นชื่อ Document)
      await FirebaseFirestore.instance.collection('users').doc(userCredential.user!.uid).set({
        'email': email, 
        'name': fullName,
        'phone': phone,
        'dateOfBirth': null,
        'profileImagePath': null,
        'createdAt': FieldValue.serverTimestamp(),
      });
      await PhoneIndexService.claim(userCredential.user!.uid, email, phone);

      if (mounted) {
        setState(() => _isLoading = false);
        context.go('/scanner'); 
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          if (e.code == 'email-already-in-use') {
            _errorMessage = 'อีเมลนี้มีผู้ใช้งานแล้ว'; 
          } else if (e.code == 'invalid-email') {
            _errorMessage = 'รูปแบบอีเมลไม่ถูกต้อง';
          } else if (e.code == 'weak-password') {
            _errorMessage = 'รหัสผ่านต้องมีอย่างน้อย 6 ตัวอักษร';
          } else {
            _errorMessage = 'เกิดข้อผิดพลาด: ${e.message}';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'เกิดข้อผิดพลาดที่ไม่รู้จัก: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        height: double.infinity,
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
              child: Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(32),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Back Button & Title
                      GestureDetector(
                        onTap: () => context.go('/login'),
                        child: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: AppTheme.textSecondary),
                      ),
                      const SizedBox(height: 16),
                      const Center(
                        child: Text(
                          'สมัครสมาชิก',
                          style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w800,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),

                      _buildLabel('email'),
                      const SizedBox(height: 8),
                      _buildTextField(ctrl: _emailCtrl, validator: (v) => v!.isEmpty ? '*' : null),
                      
                      const SizedBox(height: 16),
                      
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildLabel('ชื่อ'),
                                const SizedBox(height: 8),
                                _buildTextField(ctrl: _nameCtrl, validator: (v) => v!.isEmpty ? '*' : null),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildLabel('สกุล'),
                                const SizedBox(height: 8),
                                _buildTextField(ctrl: _surnameCtrl, validator: (v) => v!.isEmpty ? '*' : null),
                              ],
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      _buildLabel('เบอร์โทรศัพท์'),
                      const SizedBox(height: 8),
                      _buildTextField(ctrl: _phoneCtrl, keyboardType: TextInputType.phone, validator: (v) => v!.isEmpty ? '*' : null),

                      const SizedBox(height: 16),

                      // 🟢 ช่องรหัสผ่าน (เพิ่มปุ่มลูกตาเปิด-ปิด)
                      _buildLabel('รหัสผ่าน'),
                      const SizedBox(height: 8),
                      _buildTextField(
                        ctrl: _passwordCtrl, 
                        obscureText: _obscurePassword,
                        isPasswordField: true,
                        onTogglePassword: () => setState(() => _obscurePassword = !_obscurePassword),
                        validator: (v) => v!.length < 6 ? '*' : null,
                      ),

                      const SizedBox(height: 16),

                      // 🟢 ช่องยืนยันรหัสผ่าน (เพิ่มปุ่มลูกตาเปิด-ปิด)
                      _buildLabel('ยืนยันรหัสผ่าน'),
                      const SizedBox(height: 8),
                      _buildTextField(
                        ctrl: _confirmCtrl, 
                        obscureText: _obscureConfirm,
                        isPasswordField: true,
                        onTogglePassword: () => setState(() => _obscureConfirm = !_obscureConfirm),
                        validator: (v) => (v != _passwordCtrl.text || v!.isEmpty) ? '*' : null
                      ),

                      if (_errorMessage != null) ...[
                        const SizedBox(height: 12),
                        Text(_errorMessage!, style: const TextStyle(color: AppTheme.error, fontSize: 12)),
                      ],

                      const SizedBox(height: 32),

                      GradientButton(
                        label: 'ยืนยัน',
                        isLoading: _isLoading,
                        onPressed: _register,
                      ).animate(delay: 200.ms).fadeIn(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLabel(String text) => Text(
        text,
        style: const TextStyle(
          fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textPrimary,
        ),
      );

  // 🟢 ปรับแต่งฟังก์ชันสร้าง TextField ให้รองรับปุ่มดูรหัสผ่าน
  Widget _buildTextField({
    required TextEditingController ctrl,
    bool obscureText = false,
    bool isPasswordField = false,
    VoidCallback? onTogglePassword,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: ctrl,
      obscureText: obscureText,
      keyboardType: keyboardType,
      validator: validator,
      decoration: InputDecoration(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        fillColor: AppTheme.inputBg ?? Colors.grey.shade50,
        filled: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        suffixIcon: isPasswordField
            ? IconButton(
                icon: Icon(
                  obscureText ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  size: 20,
                  color: AppTheme.textHint,
                ),
                onPressed: onTogglePassword,
              )
            : null,
      ),
    );
  }
}