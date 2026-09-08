import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/widgets/gradient_button.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _logout(BuildContext context) async {
    await FirebaseAuth.instance.signOut();
    if (context.mounted) {
      context.go('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        height: double.infinity,
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: Column(
            children: [
              // ── Header ──────────────────────────────────────────────────
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
                        'การตั้งค่า',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 20), // Balance spacing
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ── Menu List ───────────────────────────────────────────────
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: ListView(
                    children: [
                      _buildMenuTile(
                        context, 
                        title: 'แก้ไขชื่อ - สกุล', 
                        icon: Icons.person_outline,
                        route: '/profile/edit-name',
                      ),
                      const SizedBox(height: 12),
                      _buildMenuTile(
                        context, 
                        title: 'แก้ไขเบอร์โทรศัพท์', 
                        icon: Icons.phone_android_outlined,
                        route: '/profile/edit-phone',
                      ),
                      const SizedBox(height: 12),
                      _buildMenuTile(
                        context, 
                        title: 'เปลี่ยนรหัสผ่าน', 
                        icon: Icons.lock_outline,
                        route: '/profile/change-password',
                      ),
                      const SizedBox(height: 12),
                      _buildMenuTile(
                        context, 
                        title: 'จัดการการเชื่อมต่อบัญชี', 
                        icon: Icons.link_rounded,
                        route: '/profile/link-email',
                      ),
                      const SizedBox(height: 32),

                      // Logout button
                      GestureDetector(
                        onTap: () => _logout(context),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFDE8E8), // Light red background
                            borderRadius: BorderRadius.circular(30),
                          ),
                          alignment: Alignment.center,
                          child: const Text(
                            'ออกจากระบบ',
                            style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.error,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMenuTile(BuildContext context, {required String title, required IconData icon, required String route}) {
    return GestureDetector(
      onTap: () => context.push(route),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.02),
              blurRadius: 10, offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppTheme.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppTheme.textPrimary),
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded, size: 16, color: AppTheme.textHint),
          ],
        ),
      ),
    );
  }
}
