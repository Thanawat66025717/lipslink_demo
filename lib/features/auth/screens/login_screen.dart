import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/services/phone_index_service.dart';
import '../../../shared/widgets/gradient_button.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart'; // 🟢 เพิ่ม Google Sign In
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart'; // 🟢 เพิ่ม Facebook Sign In

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

  // 🟢 อัปเดตฟังก์ชันล็อกอินให้รองรับเบอร์โทรศัพท์
  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return; 
    setState(() { _isLoading = true; _errorMessage = null; });

    try {
      String loginId = _emailCtrl.text.trim();
      String password = _passwordCtrl.text;
      String emailForAuth = loginId;

      // 1. เช็กว่าสิ่งที่กรอกมา เป็นเบอร์โทรศัพท์หรือไม่ (มีแต่ตัวเลข และไม่มี @)
      bool isPhoneNumber = RegExp(r'^[0-9]+$').hasMatch(loginId) && !loginId.contains('@');

      if (isPhoneNumber) {
        // 2. ถ้าเป็นเบอร์โทร ให้หาอีเมลจากตาราง phones (users อ่านได้เฉพาะเจ้าของ)
        final email = await PhoneIndexService.emailFor(loginId);

        if (email == null) {
          // ถ้าหาเบอร์นี้ไม่เจอในระบบ
          if (mounted) {
            setState(() {
              _isLoading = false;
              _errorMessage = 'ไม่พบบัญชีที่ผูกกับเบอร์โทรศัพท์นี้';
            });
          }
          return;
        }
        
        // 3. ถ้าเจอ ใช้อีเมลของเบอร์นั้นล็อกอิน
        emailForAuth = email;
      }

      // 4. ทำการล็อกอินด้วย Firebase Auth (ใช้อีเมลที่แอบหามาได้ หรืออีเมลที่ผู้ใช้กรอกตรงๆ)
      final userCredential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: emailForAuth,
        password: password,
      );
      // บัญชีที่สมัครก่อนมีตาราง phones จะได้ล็อกอินด้วยเบอร์ได้ตั้งแต่ครั้งหน้า
      await PhoneIndexService.ensureIndexed(userCredential.user!);

      if (mounted) {
        setState(() => _isLoading = false);
        context.go('/scanner'); 
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'ข้อมูลเข้าสู่ระบบไม่ถูกต้อง'; 
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'เกิดข้อผิดพลาด: $e';
        });
      }
    }
  }

  // 🟢 ฟังก์ชันสำหรับล็อกอินด้วย Google
  Future<void> _signInWithGoogle() async {
    setState(() { _isLoading = true; _errorMessage = null; });
    try {
      final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) {
        // กรณีผู้ใช้กดยกเลิก
        if (mounted) setState(() => _isLoading = false);
        return;
      }
      
      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
      final AuthCredential credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      
      final userCredential = await FirebaseAuth.instance.signInWithCredential(credential);
      
      // บันทึกข้อมูลผู้ใช้ลง Firestore ถ้ายังไม่เคยมี
      if (userCredential.user != null) {
         final userDoc = await FirebaseFirestore.instance.collection('users').doc(userCredential.user!.uid).get();
         if (!userDoc.exists) {
            await FirebaseFirestore.instance.collection('users').doc(userCredential.user!.uid).set({
               'uid': userCredential.user!.uid,
               'email': userCredential.user!.email,
               'name': userCredential.user!.displayName ?? 'ผู้ใช้ Google',
               'photoUrl': userCredential.user!.photoURL,
               'createdAt': FieldValue.serverTimestamp(),
            });
         }
      }
      
      if (mounted) {
        setState(() => _isLoading = false);
        context.go('/scanner'); 
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'ข้อผิดพลาดการล็อกอิน: ${e.message}'; 
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'เกิดข้อผิดพลาด: $e';
        });
      }
    }
  }

  // 🔵 ฟังก์ชันสำหรับล็อกอินด้วย Facebook
  Future<void> _signInWithFacebook() async {
    setState(() { _isLoading = true; _errorMessage = null; });
    try {
      final LoginResult result = await FacebookAuth.instance.login(permissions: ['email', 'public_profile']);
      
      if (result.status == LoginStatus.success) {
        final OAuthCredential credential = FacebookAuthProvider.credential(result.accessToken!.tokenString);
        final userCredential = await FirebaseAuth.instance.signInWithCredential(credential);
        
        // บันทึกข้อมูลผู้ใช้ลง Firestore ถ้ายังไม่เคยมี
        if (userCredential.user != null) {
           final userDoc = await FirebaseFirestore.instance.collection('users').doc(userCredential.user!.uid).get();
           if (!userDoc.exists) {
              await FirebaseFirestore.instance.collection('users').doc(userCredential.user!.uid).set({
                 'uid': userCredential.user!.uid,
                 'email': userCredential.user!.email,
                 'name': userCredential.user!.displayName ?? 'ผู้ใช้ Facebook',
                 'photoUrl': userCredential.user!.photoURL,
                 'createdAt': FieldValue.serverTimestamp(),
              });
           }
        }
        
        if (mounted) {
          setState(() => _isLoading = false);
          context.go('/scanner'); 
        }
      } else if (result.status == LoginStatus.cancelled) {
        if (mounted) setState(() => _isLoading = false);
      } else {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _errorMessage = 'ข้อผิดพลาด Facebook: ${result.message}'; 
          });
        }
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'ข้อผิดพลาดการล็อกอิน: ${e.message}'; 
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'เกิดข้อผิดพลาด: $e';
        });
      }
    }
  }

  Future<void> _showForgotPasswordDialog() async {
    final TextEditingController resetEmailCtrl = TextEditingController();
    
    // ถ้าผู้ใช้กรอกอีเมลไว้แล้ว (มีตัว @) ให้ดึงมาใส่ให้เลย แต่ถ้าเป็นเบอร์โทรให้เว้นว่างไว้
    if (_emailCtrl.text.contains('@')) {
      resetEmailCtrl.text = _emailCtrl.text.trim(); 
    }

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('รีเซ็ตรหัสผ่าน', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'กรุณากรอกอีเมลที่ใช้สมัครบัญชี เพื่อรับลิงก์สำหรับตั้งรหัสผ่านใหม่', 
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.5),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: resetEmailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  hintText: 'Email',
                  prefixIcon: const Icon(Icons.email_outlined, color: AppTheme.textHint),
                  filled: true,
                  fillColor: Colors.grey.shade50,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey.shade200),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.grey.shade200),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppTheme.primary),
                  ),
                ),
              ),
            ],
          ),
          actionsPadding: const EdgeInsets.only(right: 16, bottom: 16),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('ยกเลิก', style: TextStyle(color: AppTheme.textHint, fontWeight: FontWeight.w600)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              ),
              onPressed: () async {
                if (resetEmailCtrl.text.isEmpty) return;
                
                final emailToSend = resetEmailCtrl.text.trim();
                Navigator.pop(context); 

                try {
                  await FirebaseAuth.instance.sendPasswordResetEmail(email: emailToSend);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('ส่งลิงก์รีเซ็ตรหัสผ่านสำเร็จ! กรุณาเช็กอีเมลของคุณ'),
                        backgroundColor: Colors.green,
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                } on FirebaseAuthException catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('เกิดข้อผิดพลาด: ${e.message}'),
                        backgroundColor: AppTheme.error,
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                }
              },
              child: const Text('ส่งลิงก์', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return CustomScrollView(
                physics: const BouncingScrollPhysics(),
                slivers: [
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(height: 20),
                          
                          Image.asset(
                            'assets/images/lipslinklogo.png',
                            height: 90,
                            fit: BoxFit.contain,
                          ).animate().fadeIn(duration: 600.ms).scale(curve: Curves.easeOutBack),
                          
                          const SizedBox(height: 40),

                          Container(
                            padding: const EdgeInsets.all(32),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(32),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.04),
                                  blurRadius: 30,
                                  offset: const Offset(0, 10),
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
                                      fontSize: 24,
                                      fontWeight: FontWeight.w800,
                                      color: AppTheme.textPrimary,
                                      letterSpacing: -0.5,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  const Text(
                                    'ยินดีต้อนรับกลับมา กรุณาเข้าสู่ระบบ',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.textSecondary,
                                    ),
                                  ),
                                  const SizedBox(height: 32),

                                  // 🟢 แก้ไขคำแนะนำในช่องให้สอดคล้อง
                                  _buildLabel('อีเมล / เบอร์โทรศัพท์'),
                                  const SizedBox(height: 8),
                                  TextFormField(
                                    controller: _emailCtrl,
                                    keyboardType: TextInputType.emailAddress,
                                    style: const TextStyle(fontSize: 15),
                                    decoration: InputDecoration(
                                      hintText: 'กรอกอีเมลหรือเบอร์โทรศัพท์',
                                      prefixIcon: const Icon(Icons.person_outline, color: AppTheme.textHint, size: 22),
                                      filled: true,
                                      fillColor: AppTheme.inputBg ?? Colors.grey.shade50,
                                      contentPadding: const EdgeInsets.symmetric(vertical: 16),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(16),
                                        borderSide: BorderSide.none,
                                      ),
                                    ),
                                    validator: (v) => (v == null || v.isEmpty) ? 'กรุณากรอกข้อมูล' : null,
                                  ).animate(delay: 100.ms).fadeIn().slideX(begin: -0.05),

                                  const SizedBox(height: 20),

                                  _buildLabel('รหัสผ่าน'),
                                  const SizedBox(height: 8),
                                  TextFormField(
                                    controller: _passwordCtrl,
                                    obscureText: _obscurePassword,
                                    style: const TextStyle(fontSize: 15),
                                    decoration: InputDecoration(
                                      hintText: '••••••••',
                                      prefixIcon: const Icon(Icons.lock_outline, color: AppTheme.textHint, size: 22),
                                      filled: true,
                                      fillColor: AppTheme.inputBg ?? Colors.grey.shade50,
                                      contentPadding: const EdgeInsets.symmetric(vertical: 16),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(16),
                                        borderSide: BorderSide.none,
                                      ),
                                      suffixIcon: IconButton(
                                        icon: Icon(
                                          _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                          color: AppTheme.textHint,
                                          size: 20,
                                        ),
                                        onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                                      ),
                                    ),
                                    validator: (v) => (v == null || v.isEmpty) ? 'กรุณากรอกรหัสผ่าน' : null,
                                  ).animate(delay: 150.ms).fadeIn().slideX(begin: -0.05),

                                  const SizedBox(height: 12),

                                  
                                   Align(
                                      alignment: Alignment.centerRight,
                                        child: GestureDetector(
                                           onTap: () => context.push('/forgot-password'), // 🟢 เปลี่ยนมาเรียกหน้า OTP ใหม่ตรงนี้ครับ
                                          child: const Text(
                                                  'ลืมรหัสผ่าน?',
                                          style: TextStyle(
                                          fontSize: 13,
                                          color: AppTheme.primary,
                                          fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                     ),
                                  ).animate(delay: 150.ms).fadeIn().slideX(begin: -0.05),
                                  if (_errorMessage != null) ...[
                                    const SizedBox(height: 16),
                                    Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: AppTheme.error.withOpacity(0.1),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(Icons.error_outline, color: AppTheme.error, size: 18),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              _errorMessage!,
                                              style: const TextStyle(color: AppTheme.error, fontSize: 13, fontWeight: FontWeight.w500),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ).animate().shake(),
                                  ],

                                  const SizedBox(height: 32),

                                  SizedBox(
                                    width: double.infinity,
                                    height: 52,
                                    child: GradientButton(
                                      label: 'เข้าสู่ระบบ',
                                      isLoading: _isLoading,
                                      onPressed: _login,
                                    ),
                                  ).animate(delay: 200.ms).fadeIn().slideY(begin: 0.1),
                                  
                                  const SizedBox(height: 24),
                                  
                                  Row(
                                    children: [
                                      Expanded(child: Divider(color: Colors.grey.shade300)),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 16),
                                        child: Text('หรือ', style: TextStyle(color: AppTheme.textHint, fontSize: 13, fontWeight: FontWeight.w500)),
                                      ),
                                      Expanded(child: Divider(color: Colors.grey.shade300)),
                                    ],
                                  ).animate(delay: 250.ms).fadeIn(),
                                  
                                  const SizedBox(height: 24),
                                  
                                  SizedBox(
                                    width: double.infinity,
                                    height: 52,
                                    child: OutlinedButton(
                                      style: OutlinedButton.styleFrom(
                                        backgroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                        side: BorderSide(color: Colors.grey.shade300),
                                        elevation: 0,
                                      ),
                                      onPressed: _isLoading ? null : _signInWithGoogle,
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          const Text('G ', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.w900, fontSize: 20)),
                                          const SizedBox(width: 8),
                                          const Text('เข้าสู่ระบบด้วย Google', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.w600, fontSize: 15)),
                                        ],
                                      ),
                                    ),
                                  ).animate(delay: 300.ms).fadeIn().slideY(begin: 0.1),

                                  const SizedBox(height: 16),

                                  SizedBox(
                                    width: double.infinity,
                                    height: 52,
                                    child: ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF1877F2), // Facebook Blue
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                        elevation: 0,
                                      ),
                                      onPressed: _isLoading ? null : _signInWithFacebook,
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          const Text('f ', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 24, fontStyle: FontStyle.italic)),
                                          const SizedBox(width: 8),
                                          const Text('เข้าสู่ระบบด้วย Facebook', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15)),
                                        ],
                                      ),
                                    ),
                                  ).animate(delay: 350.ms).fadeIn().slideY(begin: 0.1),

                                  const SizedBox(height: 32),

                                  Center(
                                    child: GestureDetector(
                                      onTap: () => context.go('/register'),
                                      child: RichText(
                                        text: const TextSpan(
                                          text: 'ยังไม่มีบัญชีผู้ใช้? ',
                                          style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                                          children: [
                                            TextSpan(
                                              text: 'สมัครสมาชิก',
                                              style: TextStyle(
                                                color: AppTheme.primary,
                                                fontWeight: FontWeight.w700,
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
                          
                          const SizedBox(height: 20),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildLabel(String text) => Text(
        text,
        style: const TextStyle(
          fontSize: 14, 
          fontWeight: FontWeight.w600, 
          color: AppTheme.textPrimary,
        ),
      );
}