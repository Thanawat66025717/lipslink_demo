import 'dart:io';
import 'dart:convert'; // 🟢 เพิ่มตัวแปลงรูปเป็นตัวอักษร (Base64)
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/models/user_model.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
// ❌ เอา Firebase Storage ออกไปเลย ไม่ต้องง้อแล้วครับ!

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
    final userAuth = FirebaseAuth.instance.currentUser;
    
    if (userAuth != null) {
      try {
        DocumentSnapshot doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(userAuth.uid)
            .get();

        if (doc.exists && mounted) {
          final data = doc.data() as Map<String, dynamic>;
          setState(() {
            _user = UserModel(
              id: userAuth.uid, 
              email: data['email'] ?? data['username'] ?? '', 
              name: data['name'] ?? userAuth.displayName ?? 'ไม่มีชื่อ',
              phone: data['phone'] ?? '',
              dateOfBirth: data['dateOfBirth'] != null ? DateTime.parse(data['dateOfBirth']) : null,
              profileImagePath: data['profileImagePath'],
              createdAt: data['createdAt'] != null 
                  ? (data['createdAt'] as Timestamp).toDate() 
                  : DateTime.now(), 
            );
          });
        } else {
          if (mounted) {
            setState(() {
              _user = UserModel(
                id: userAuth.uid,
                email: userAuth.email ?? '',
                name: userAuth.displayName ?? 'ไม่พบข้อมูลในระบบ',
                phone: 'ยังไม่ได้ระบุ',
                createdAt: DateTime.now(),
              );
            });
          }
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _user = UserModel(
              id: userAuth.uid,
              email: userAuth.email ?? 'Error',
              name: 'เกิดข้อผิดพลาดในการโหลดข้อมูล',
              phone: '',
              createdAt: DateTime.now(),
            );
          });
        }
      }
    }
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery, 
      maxWidth: 512, 
      maxHeight: 512, 
      imageQuality: 70, // 🟢 บีบอัดเพิ่มอีกนิด เพื่อให้ข้อความสั้นลง โหลดไวขึ้น
    );
    
    if (picked == null) return; 

    final userAuth = FirebaseAuth.instance.currentUser;
    if (userAuth != null) {
      try {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('กำลังอัปเดตรูปภาพ...⏳'), duration: Duration(seconds: 2)),
          );
        }

        // 🟢 1. อ่านรูปภาพออกมาเป็นข้อมูลดิบ (Bytes)
        final bytes = await picked.readAsBytes();

        // 🟢 2. แปลงรูปภาพเป็นรหัสข้อความ (Base64 String)
        String base64Image = base64Encode(bytes);

        // 🟢 3. บันทึกข้อความรูปลง Firestore ตรงๆ เลย
        await FirebaseFirestore.instance
            .collection('users')
            .doc(userAuth.uid)
            .update({'profileImagePath': base64Image});

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('อัปเดตรูปโปรไฟล์สำเร็จ! ✅'), backgroundColor: Colors.green),
          );
        }
        
        await _loadUser(); 

      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('❌ เกิดข้อผิดพลาด: $e'), backgroundColor: AppTheme.error),
          );
        }
      }
    }
  }

  Future<void> _openSettings() async {
    await context.push('/profile/settings');
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
      final userAuth = FirebaseAuth.instance.currentUser; 
      if (userAuth != null) {
        try {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(userAuth.uid)
              .update({'dateOfBirth': picked.toIso8601String()});

          await _loadUser();
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('❌ เกิดข้อผิดพลาด: $e'), backgroundColor: AppTheme.error),
            );
          }
        }
      }
    }
  }

  String _formatDate(DateTime? date) {
    if (date == null) return 'ยังไม่ได้ระบุ';
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final year = date.year + 543;
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
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const SizedBox(width: 24),
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
                Stack(
                  alignment: Alignment.center,
                  children: [
                    GestureDetector(
                      onTap: _pickImage,
                      child: Container(
                        width: 100, height: 100,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0xFFD4AF37), width: 3),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 10, offset: const Offset(0, 5),
                            ),
                          ],
                        ),
                        clipBehavior: Clip.antiAlias,
                        
                        // 🟢 เปลี่ยนวิธีแสดงผลรูป: ถ้าเป็นรหัส Base64 ให้ใช้ Image.memory แปลงกลับมาเป็นรูป
                        child: (_user!.profileImagePath != null && _user!.profileImagePath!.isNotEmpty)
                            ? (_user!.profileImagePath!.startsWith('http') 
                                ? Image.network(_user!.profileImagePath!, fit: BoxFit.cover) 
                                : Image.memory(base64Decode(_user!.profileImagePath!), fit: BoxFit.cover))
                            : Container(
                                color: Colors.white,
                                child: const Center(
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
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      _buildInfoPill('อีเมล', _user!.email),
                      const SizedBox(height: 12),
                      _buildInfoPill('ชื่อ - สกุล', _user!.name),
                      const SizedBox(height: 12),
                      _buildInfoPill('เบอร์โทรศัพท์', _user!.phone),
                      const SizedBox(height: 12),
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