import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/models/user_model.dart';
import '../../../shared/services/storage_service.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  UserModel? _user;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    final user = await StorageService.getCurrentUser();
    if (mounted) setState(() => _user = user);
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 85,
    );
    if (picked == null || _user == null) return;
    await StorageService.updateUser(_user!.copyWith(profileImagePath: picked.path));
    await _loadUser();
  }

  Future<void> _openSettings() async {
    await context.push('/profile/settings');
    // Reload user when returning from settings in case they edited info
    _loadUser();
  }

  Future<void> _pickDate() async {
    final initialDate = _user?.dateOfBirth ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: AppTheme.primary,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null && picked != _user?.dateOfBirth && _user != null) {
      await StorageService.updateUser(_user!.copyWith(dateOfBirth: picked));
      await _loadUser();
    }
  }

  String _formatDate(DateTime? date) {
    if (date == null) return 'ยังไม่ได้ระบุ';
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final year = date.year + 543; // Convert to Buddhist Era
    return '$day/$month/$year';
  }

  @override
  Widget build(BuildContext context) {
    if (_user == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: Container(
        height: double.infinity,
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              children: [
                // ── Header ──────────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const SizedBox(width: 24), // Spacer
                      const Text(
                        'Profile',
                        style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      GestureDetector(
                        onTap: _openSettings, 
                        child: const Icon(Icons.settings_outlined, color: AppTheme.textPrimary, size: 24),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // ── Avatar ──────────────────────────────────────────────────
                Stack(
                  alignment: Alignment.center,
                  children: [
                    GestureDetector(
                      onTap: _pickImage,
                      child: Container(
                        width: 100, height: 100,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0xFFD4AF37), width: 3), // Gold border
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 10, offset: const Offset(0, 5),
                            ),
                          ],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: _user!.profileImagePath != null
                            ? Image.file(File(_user!.profileImagePath!), fit: BoxFit.cover)
                            : Container(
                                color: Colors.white,
                                child: Center(
                                  child: Icon(Icons.person, size: 50, color: AppTheme.textHint),
                                ),
                              ),
                      ),
                    ),
                    Positioned(
                      bottom: -4, right: -4,
                      child: GestureDetector(
                        onTap: _pickImage,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.edit_outlined, color: AppTheme.textSecondary, size: 16),
                        ),
                      ),
                    ),
                  ],
                ).animate().scale(duration: 400.ms, curve: Curves.elasticOut),

                const SizedBox(height: 40),

                // ── Info Section (Read-only) ─────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      _buildInfoPill('ชื่อผู้ใช้', _user!.email),
                      const SizedBox(height: 12),
                      _buildInfoPill('ชื่อ - สกุล', _user!.name),
                      const SizedBox(height: 12),
                      _buildInfoPill('เบอร์โทรศัพท์', _user!.phone),
                      const SizedBox(height: 12),
                      // Date field with clickable icon
                      _buildInfoPill(
                        'วันเกิด', 
                        _formatDate(_user!.dateOfBirth), 
                        isDate: true,
                        onIconTap: _pickDate,
                      ),
                      
                      const SizedBox(height: 24),
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

  Widget _buildInfoPill(String label, String value, {bool isDate = false, VoidCallback? onIconTap}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: AppTheme.inputBg,
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppTheme.textPrimary),
            ),
          ),
          if (isDate)
            GestureDetector(
              onTap: onIconTap,
              child: const Icon(Icons.calendar_today_outlined, size: 18, color: AppTheme.primary),
            )
        ],
      ),
    );
  }
}
