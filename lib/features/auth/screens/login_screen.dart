import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/services/storage_service.dart';
import '../../../shared/widgets/gradient_button.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _isLoading = true; _errorMessage = null; });
    final user = await StorageService.login(_emailCtrl.text.trim(), _passwordCtrl.text);
    if (mounted) {
      setState(() => _isLoading = false);
      if (user != null) {
        context.go('/scanner');
      } else {
        setState(() => _errorMessage = 'อีเมลหรือรหัสผ่านไม่ถูกต้อง');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              children: [
                const SizedBox(height: 60),
                // Logo Image
                Image.asset(
                  'assets/images/lipslinklogo.png',
                  height: 80,
                  fit: BoxFit.contain,
                ).animate().fadeIn(),
                
                const SizedBox(height: 40),

                // Main Card
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
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
                        const Text(
                          'เข้าสู่ระบบ',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 24),

                        _buildLabel('ชื่อบัญชีผู้ใช้/เบอร์โทรศัพท์'),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _emailCtrl,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(
                            hintText: 'Username/Phone Number',
                            prefixIcon: Icon(Icons.person_outline, color: AppTheme.textHint),
                          ),
                          validator: (v) => (v == null || v.isEmpty) ? 'กรุณากรอกข้อมูล' : null,
                        ).animate(delay: 100.ms).fadeIn().slideX(begin: -0.05),

                        const SizedBox(height: 16),

                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _buildLabel('รหัสผ่าน'),
                            GestureDetector(
                              onTap: () {}, // TODO: Forgot password
                              child: const Text(
                                'ลืมรหัสผ่าน?',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.primary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _passwordCtrl,
                          obscureText: _obscurePassword,
                          decoration: InputDecoration(
                            hintText: 'Password',
                            prefixIcon: const Icon(Icons.lock_outline, color: AppTheme.textHint),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscurePassword ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
                                color: AppTheme.textHint,
                              ),
                              onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                            ),
                          ),
                          validator: (v) => (v == null || v.isEmpty) ? 'กรุณากรอกรหัสผ่าน' : null,
                        ).animate(delay: 150.ms).fadeIn().slideX(begin: -0.05),

                        if (_errorMessage != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _errorMessage!,
                            style: const TextStyle(color: AppTheme.error, fontSize: 12),
                          ).animate().shake(),
                        ],

                        const SizedBox(height: 32),

                        GradientButton(
                          label: 'เข้าสู่ระบบ',
                          isLoading: _isLoading,
                          onPressed: _login,
                        ).animate(delay: 200.ms).fadeIn().slideY(begin: 0.1),
                        
                        const SizedBox(height: 24),

                        Center(
                          child: GestureDetector(
                            onTap: () => context.go('/register'),
                            child: RichText(
                              text: const TextSpan(
                                text: 'ยังไม่มีบัญชีผู้ใช้? ',
                                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                                children: [
                                  TextSpan(
                                    text: 'สมัครสมาชิก',
                                    style: TextStyle(
                                      color: AppTheme.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ).animate(delay: 250.ms).fadeIn(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLabel(String text) => Text(
        text,
        style: const TextStyle(
          fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary,
        ),
      );
}
