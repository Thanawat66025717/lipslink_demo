import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/services/storage_service.dart';
import '../../../shared/widgets/gradient_button.dart';

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});
  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _oldCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _otpCtrl = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() { 
    _oldCtrl.dispose(); _newCtrl.dispose(); _confirmCtrl.dispose();
    _phoneCtrl.dispose(); _otpCtrl.dispose();
    super.dispose(); 
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);
    // Simulate API delay
    await Future.delayed(const Duration(milliseconds: 600));
    // In a real app we'd verify old password and update it. 
    if (mounted) { setState(() => _isLoading = false); context.pop(); }
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
                        'Reset Password',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 20), // Balance
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
                        _buildField(label: 'รหัสผ่านเดิม', ctrl: _oldCtrl, obscure: true),
                        const SizedBox(height: 16),
                        _buildField(label: 'รหัสผ่านใหม่', ctrl: _newCtrl, obscure: true),
                        const SizedBox(height: 16),
                        _buildField(label: 'ยืนยันรหัสผ่าน', ctrl: _confirmCtrl, obscure: true),
                        const SizedBox(height: 16),
                        
                        // Phone and OTP row
                        Row(
                          children: [
                            const SizedBox(
                              width: 80,
                              child: Text('เบอร์โทรศัพท์', style: TextStyle(fontSize: 10, color: AppTheme.textHint)),
                            ),
                            Expanded(
                              child: TextFormField(
                                controller: _phoneCtrl,
                                keyboardType: TextInputType.phone,
                                decoration: InputDecoration(
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                  fillColor: AppTheme.inputBg,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: () {
                                // Handle Request OTP
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFDE8E8), // Light red/orange
                                  borderRadius: BorderRadius.circular(30),
                                ),
                                child: const Center(
                                  child: Text('รับ OTP', style: TextStyle(fontSize: 11, color: Colors.black87, fontWeight: FontWeight.w600)),
                                ),
                              ),
                            ),
                          ],
                        ),
                        
                        const SizedBox(height: 16),
                        
                        Row(
                          children: [
                            const SizedBox(width: 80),
                            Expanded(
                              child: TextFormField(
                                controller: _otpCtrl,
                                textAlign: TextAlign.center,
                                decoration: InputDecoration(
                                  hintText: 'รหัส OTP',
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                  fillColor: AppTheme.inputBg,
                                ),
                              ),
                            ),
                            const SizedBox(width: 60), // Balance to keep it somewhat centered or aligned
                          ],
                        ),

                        const SizedBox(height: 40),
                        
                        Center(
                          child: SizedBox(
                            width: 150,
                            child: GradientButton(
                              label: 'ยืนยัน', 
                              isLoading: _isLoading, 
                              onPressed: _save,
                              isSecondary: true, // Use green button
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

  Widget _buildField({required String label, required TextEditingController ctrl, bool obscure = false}) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(fontSize: 10, color: AppTheme.textHint),
          ),
        ),
        Expanded(
          child: TextFormField(
            controller: ctrl,
            obscureText: obscure,
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              fillColor: AppTheme.inputBg,
            ),
          ),
        ),
      ],
    );
  }
}
