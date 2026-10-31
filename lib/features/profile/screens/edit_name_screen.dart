import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../app/theme/app_theme.dart';
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
    _loadCurrentName();
  }

  // 🟢 ฟังก์ชันดึงชื่อเดิมจาก Firebase Firestore
  Future<void> _loadCurrentName() async {
    final userAuth = FirebaseAuth.instance.currentUser;
    if (userAuth != null) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(userAuth.uid)
            .get();
            
        if (doc.exists && mounted) {
          setState(() {
            _ctrl.text = doc.data()?['name'] ?? '';
          });
        }
      } catch (e) {
        debugPrint('โหลดชื่อไม่สำเร็จ: $e');
      }
    }
  }

  @override
  void dispose() { 
    _ctrl.dispose(); 
    super.dispose(); 
  }

  // 🟢 ฟังก์ชันอัปเดตชื่อขึ้น Firebase Firestore
  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    
    setState(() => _isLoading = true);
    
    try {
      final userAuth = FirebaseAuth.instance.currentUser;
      if (userAuth != null) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(userAuth.uid)
            .update({'name': _ctrl.text.trim()});
            
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('อัปเดตชื่อสำเร็จ! ✅'),
              backgroundColor: Colors.green,
            ),
          );
          context.pop(); // เปลี่ยนชื่อเสร็จแล้วให้กลับหน้าเดิม
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('เกิดข้อผิดพลาด: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => _EditScaffold(
    title: 'แก้ไขชื่อ-สกุล', // เปลี่ยนชื่อ Title ให้อ่านง่ายขึ้น
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
                    filled: true, // อย่าลืมใส่ filled: true เพื่อให้สีพื้นหลังทำงาน
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
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
                // ลบ isSecondary ออกเพราะคุณอาจจะไม่ได้ตั้งค่ารับพารามิเตอร์นี้ใน GradientButton ของคุณ
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
