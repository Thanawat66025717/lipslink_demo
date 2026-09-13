import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../app/theme/app_theme.dart';
import '../../../shared/services/onboarding_prefs.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    await Future.delayed(const Duration(seconds: 2));

    // ผู้ใช้ที่ล็อกอินค้างอยู่ถือว่าผ่านหน้าแนะนำมาแล้ว จึงเช็คสถานะล็อกอินก่อน
    // ไม่งั้นคนที่เคยลบข้อมูลแอปแล้วล็อกอินใหม่จะโดนหน้าแนะนำคั่นทุกครั้ง
    if (FirebaseAuth.instance.currentUser != null) {
      if (mounted) context.go('/scanner');
      return;
    }

    final seenOnboarding = await OnboardingPrefs.hasSeen();
    if (!mounted) return;
    context.go(seenOnboarding ? '/login' : '/onboarding');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: AppTheme.backgroundGradient,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Logo Image
            Image.asset(
              'assets/images/lipslinklogo.png',
              width: 140,
              height: 140,
              fit: BoxFit.contain,
            )
            .animate()
            .scale(duration: 600.ms, curve: Curves.easeOutBack)
            .fadeIn(),
            
            const SizedBox(height: 24),
            
            // LIPLINK Text
            const Text(
              'LIPLINK',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w800,
                color: AppTheme.primary,
                letterSpacing: 2.0,
              ),
            )
            .animate(delay: 300.ms)
            .fadeIn(duration: 500.ms)
            .slideY(begin: 0.2, end: 0),
          ],
        ),
      ),
    );
  }
}
