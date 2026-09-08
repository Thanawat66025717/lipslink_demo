import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/widgets/gradient_button.dart';

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});
  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();

  // controllers
  final _currentCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  // state variables
  bool _isLoading = false;

  // ตัวแปรสำหรับซ่อน/แสดงรหัสผ่าน
  bool _obscureCurrentPass = true;
  bool _obscureNewPass = true;
  bool _obscureConfirmPass = true;

  @override
  void dispose() {
    _currentCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  // ── ยืนยันรหัสผ่านเดิม แล้วเปลี่ยนรหัสผ่านใหม่ ──
  Future<void> _changePassword() async {
    if (!_formKey.currentState!.validate()) return;

    if (_newCtrl.text != _confirmCtrl.text) {
      _showError('รหัสผ่านใหม่ไม่ตรงกัน');
      return;
    }
    if (_newCtrl.text.length < 6) {
      _showError('รหัสผ่านต้องมีอย่างน้อย 6 ตัวอักษร');
      return;
    }
    if (_currentCtrl.text == _newCtrl.text) {
      _showError('รหัสผ่านใหม่ต้องไม่ซ้ำกับรหัสผ่านเดิม');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || user.email == null) {
        _showError('ไม่พบข้อมูลผู้ใช้ กรุณาล็อกอินใหม่');
        setState(() => _isLoading = false);
        return;
      }

      // ยืนยันตัวตนด้วยรหัสผ่านเดิม (Email/Password)
      final credential = EmailAuthProvider.credential(
        email: user.email!,
        password: _currentCtrl.text,
      );
      await user.reauthenticateWithCredential(credential);

      // อัปเดตรหัสผ่านใหม่
      await user.updatePassword(_newCtrl.text);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('เปลี่ยนรหัสผ่านสำเร็จ! ✅'), backgroundColor: Colors.green),
        );
        context.pop();
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() => _isLoading = false);
      if (e.code == 'wrong-password' || e.code == 'invalid-credential') {
        _showError('รหัสผ่านเดิมไม่ถูกต้อง');
      } else if (e.code == 'weak-password') {
        _showError('รหัสผ่านใหม่ไม่ปลอดภัยเพียงพอ');
      } else {
        _showError('เกิดข้อผิดพลาด: ${e.message}');
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
      _showError('เกิดข้อผิดพลาด: $e');
    }
  }

  void _showError(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: AppTheme.error),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Container(
      height: double.infinity,
      decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => context.pop(),
                      child: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: AppTheme.textSecondary),
                    ),
                    const Expanded(
                      child: Text(
                        'เปลี่ยนรหัสผ่าน',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 20),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Container(
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(32),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 24, offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [

                        // ── ฟิลด์: รหัสผ่านเดิม ──
                        Row(
                          children: [
                            const SizedBox(
                              width: 80,
                              child: Text('รหัสผ่านเดิม', style: TextStyle(fontSize: 10, color: AppTheme.textHint)),
                            ),
                            Expanded(
                              child: TextFormField(
                                controller: _currentCtrl,
                                obscureText: _obscureCurrentPass,
                                decoration: InputDecoration(
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                  fillColor: AppTheme.inputBg,
                                  filled: true,
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscureCurrentPass ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                      color: AppTheme.textHint,
                                      size: 18,
                                    ),
                                    onPressed: () {
                                      setState(() => _obscureCurrentPass = !_obscureCurrentPass);
                                    },
                                  ),
                                ),
                                validator: (v) => v!.isEmpty ? '*' : null,
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 16),

                        // ── ฟิลด์: รหัสผ่านใหม่ ──
                        Row(
                          children: [
                            const SizedBox(
                              width: 80,
                              child: Text('รหัสผ่านใหม่', style: TextStyle(fontSize: 10, color: AppTheme.textHint)),
                            ),
                            Expanded(
                              child: TextFormField(
                                controller: _newCtrl,
                                obscureText: _obscureNewPass,
                                decoration: InputDecoration(
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                  fillColor: AppTheme.inputBg,
                                  filled: true,
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscureNewPass ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                      color: AppTheme.textHint,
                                      size: 18,
                                    ),
                                    onPressed: () {
                                      setState(() => _obscureNewPass = !_obscureNewPass);
                                    },
                                  ),
                                ),
                                validator: (v) => v!.isEmpty ? '*' : null,
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 16),

                        // ── ฟิลด์: ยืนยันรหัสผ่าน ──
                        Row(
                          children: [
                            const SizedBox(
                              width: 80,
                              child: Text('ยืนยันรหัสผ่าน', style: TextStyle(fontSize: 10, color: AppTheme.textHint)),
                            ),
                            Expanded(
                              child: TextFormField(
                                controller: _confirmCtrl,
                                obscureText: _obscureConfirmPass,
                                decoration: InputDecoration(
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                  fillColor: AppTheme.inputBg,
                                  filled: true,
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscureConfirmPass ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                      color: AppTheme.textHint,
                                      size: 18,
                                    ),
                                    onPressed: () {
                                      setState(() => _obscureConfirmPass = !_obscureConfirmPass);
                                    },
                                  ),
                                ),
                                validator: (v) => v!.isEmpty ? '*' : null,
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 40),

                        Center(
                          child: SizedBox(
                            width: 150,
                            child: GradientButton(
                              label: 'ยืนยัน',
                              isLoading: _isLoading,
                              onPressed: _changePassword,
                            ).animate(delay: 100.ms).fadeIn(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
    ),
  );
}