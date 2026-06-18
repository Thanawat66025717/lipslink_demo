import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/services/storage_service.dart';
import '../../../shared/widgets/gradient_button.dart';

class EditNameScreen extends StatefulWidget {
  const EditNameScreen({super.key});
  @override
  State<EditNameScreen> createState() => _EditNameScreenState();
}

class _EditNameScreenState extends State<EditNameScreen> {
  final _formKey = GlobalKey<FormState>();
  final _ctrl = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    StorageService.getCurrentUser().then((u) {
      if (mounted && u != null) _ctrl.text = u.name;
    });
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);
    final user = await StorageService.getCurrentUser();
    if (user != null) {
      await StorageService.updateUser(user.copyWith(name: _ctrl.text.trim()));
    }
    if (mounted) { setState(() => _isLoading = false); context.pop(); }
  }

  @override
  Widget build(BuildContext context) => _EditScaffold(
    title: 'RENAME',
    child: Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 60,
                child: Text(
                  'ชื่อ - สกุล',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
              ),
              Expanded(
                child: TextFormField(
                  controller: _ctrl,
                  decoration: InputDecoration(
                    hintText: 'กรอกชื่อใหม่',
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    fillColor: AppTheme.inputBg,
                  ),
                  validator: (v) => (v?.isEmpty == true) ? '*' : null,
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
                onPressed: _save,
                isSecondary: true, // Use green button
              ).animate(delay: 100.ms).fadeIn(),
            ),
          ),
        ],
      ),
    ),
  );
}

// Shared scaffold for edit screens
class _EditScaffold extends StatelessWidget {
  final String title;
  final Widget child;
  const _EditScaffold({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
                      Expanded(
                        child: Text(
                          title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 20), // Balance
                    ],
                  ),
                ),
                const SizedBox(height: 20),
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
                    child: child,
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
