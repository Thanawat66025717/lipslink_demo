import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/services/storage_service.dart';
import '../../../shared/widgets/gradient_button.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _surnameCtrl = TextEditingController(); // Added surname for UI
  final _emailCtrl = TextEditingController(); // Using as username
  final _phoneCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

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
    final ok = await StorageService.register(
      name: '${_nameCtrl.text.trim()} ${_surnameCtrl.text.trim()}',
      email: _emailCtrl.text.trim(),
      phone: _phoneCtrl.text.trim(),
      password: _passwordCtrl.text,
    );
    if (mounted) {
      setState(() => _isLoading = false);
      if (ok) {
        context.go('/scanner');
      } else {
        setState(() => _errorMessage = 'เกิดข้อผิดพลาดในการลงทะเบียน');
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

                      _buildLabel('ชื่อบัญชีผู้ใช้'),
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

                      _buildLabel('รหัสผ่าน'),
                      const SizedBox(height: 8),
                      _buildTextField(ctrl: _passwordCtrl, obscureText: true, validator: (v) => v!.length < 6 ? '*' : null),

                      const SizedBox(height: 16),

                      _buildLabel('ยืนยันรหัสผ่าน'),
                      const SizedBox(height: 8),
                      _buildTextField(
                        ctrl: _confirmCtrl, 
                        obscureText: true, 
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

  Widget _buildTextField({
    required TextEditingController ctrl,
    bool obscureText = false,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: ctrl,
      obscureText: obscureText,
      keyboardType: keyboardType,
      validator: validator,
      // Default theme applied from AppTheme
    );
  }
}
