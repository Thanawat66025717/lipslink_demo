import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/widgets/gradient_button.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();

  bool _isLoading = false;
  bool _emailSent = false;

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  // ส่งลิงก์รีเซ็ตรหัสผ่านไปยังอีเมล
  Future<void> _sendResetEmail() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(
        email: _emailCtrl.text.trim(),
      );

      if (mounted) {
        setState(() {
          _isLoading = false;
          _emailSent = true;
        });
      }
    } on FirebaseAuthException catch (e) {
      setState(() => _isLoading = false);
      if (e.code == 'user-not-found') {
        _showError('ไม่พบบัญชีผู้ใช้ที่ผูกกับอีเมลนี้');
      } else if (e.code == 'invalid-email') {
        _showError('รูปแบบอีเมลไม่ถูกต้อง');
      } else {
        _showError('เกิดข้อผิดพลาด: ${e.message}');
      }
    } catch (e) {
      setState(() => _isLoading = false);
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
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        height: double.infinity,
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () => context.pop(),
                  child: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 24),
                const Text(
                  'รีเซ็ตรหัสผ่าน',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                ),
                const SizedBox(height: 8),
                const Text(
                  'กรอกอีเมลที่ใช้สมัครบัญชี เพื่อรับลิงก์สำหรับตั้งรหัสผ่านใหม่',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 32),

                Container(
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(32),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 30, offset: const Offset(0, 10)),
                    ],
                  ),
                  child: _emailSent ? _buildSuccessView() : _buildFormView(),
                ).animate().fadeIn().slideY(begin: 0.1),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // แสดงฟอร์มกรอกอีเมล
  Widget _buildFormView() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ไอคอนอีเมลตรงกลาง
          Center(
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppTheme.primary.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.email_outlined, size: 36, color: AppTheme.primary),
            ),
          ),
          const SizedBox(height: 24),

          const Text('อีเมล', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextFormField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              hintText: 'example@email.com',
              prefixIcon: const Icon(Icons.mail_outline_rounded, color: AppTheme.textHint, size: 20),
              filled: true,
              fillColor: AppTheme.inputBg ?? Colors.grey.shade50,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
            validator: (v) {
              if (v == null || v.isEmpty) return 'กรุณากรอกอีเมล';
              if (!v.contains('@')) return 'รูปแบบอีเมลไม่ถูกต้อง';
              return null;
            },
          ),

          const SizedBox(height: 36),

          SizedBox(
            width: double.infinity,
            height: 52,
            child: GradientButton(
              label: 'ส่งลิงก์รีเซ็ตรหัสผ่าน',
              isLoading: _isLoading,
              onPressed: _sendResetEmail,
            ),
          ),
        ],
      ),
    );
  }

  // แสดงหน้าสำเร็จหลังส่งอีเมลแล้ว
  Widget _buildSuccessView() {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: Colors.green.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.mark_email_read_outlined, size: 36, color: Colors.green),
        ).animate().scale(curve: Curves.easeOutBack),
        const SizedBox(height: 20),
        const Text(
          'ส่งลิงก์เรียบร้อยแล้ว! ✉️',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
        ),
        const SizedBox(height: 12),
        Text(
          'เราได้ส่งลิงก์สำหรับตั้งรหัสผ่านใหม่ไปที่\n${_emailCtrl.text.trim()}\n\nกรุณาเปิดอีเมลและคลิกลิงก์เพื่อตั้งรหัสผ่านใหม่',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.6),
        ),
        const SizedBox(height: 32),

        // ปุ่มส่งอีเมลอีกครั้ง
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: AppTheme.primary.withOpacity(0.3)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            onPressed: _isLoading
                ? null
                : () {
                    setState(() => _emailSent = false);
                  },
            child: const Text('ส่งอีกครั้ง', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),

        const SizedBox(height: 12),

        // ปุ่มกลับหน้า Login
        SizedBox(
          width: double.infinity,
          height: 52,
          child: GradientButton(
            label: 'กลับไปเข้าสู่ระบบ',
            isLoading: false,
            onPressed: () => context.go('/login'),
          ),
        ),
      ],
    );
  }
}