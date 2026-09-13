import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../features/auth/screens/splash_screen.dart';
import '../features/onboarding/screens/onboarding_screen.dart';
import '../features/auth/screens/login_screen.dart';
import '../features/auth/screens/register_screen.dart';
import '../features/auth/screens/forgot_password_screen.dart'; // 🟢 1. อย่าลืม Import ไฟล์นี้เข้ามาด้วยนะครับ
import '../features/scanner/screens/scanner_screen.dart';
import '../features/history/screens/history_screen.dart';
import '../features/profile/screens/profile_screen.dart';
import '../features/profile/screens/edit_name_screen.dart';
import '../features/profile/screens/edit_phone_screen.dart';
import '../features/profile/screens/change_password_screen.dart';
import '../features/profile/screens/link_email_screen.dart';
import '../shared/widgets/main_shell.dart';
import 'theme/app_theme.dart';
import '../features/profile/screens/settings_screen.dart';

final _router = GoRouter(
  initialLocation: '/splash',
  routes: [
    GoRoute(
      path: '/splash',
      builder: (context, state) => const SplashScreen(),
    ),
    GoRoute(
      path: '/onboarding',
      builder: (context, state) => const OnboardingScreen(),
    ),
    GoRoute(
      path: '/login',
      builder: (context, state) => const LoginScreen(),
    ),
    GoRoute(
      path: '/register',
      builder: (context, state) => const RegisterScreen(),
    ),
    // 🟢 2. เพิ่มเส้นทางไปหน้าลืมรหัสผ่านตรงนี้ครับ
    GoRoute(
      path: '/forgot-password',
      builder: (context, state) => const ForgotPasswordScreen(),
    ),
    ShellRoute(
      builder: (context, state, child) => MainShell(child: child),
      routes: [
        GoRoute(
          path: '/scanner',
          builder: (context, state) => const ScannerScreen(),
        ),
        GoRoute(
          path: '/history',
          builder: (context, state) => const HistoryScreen(),
        ),
        GoRoute(
          path: '/profile',
          builder: (context, state) => const ProfileScreen(),
        ),
      ],
    ),
    GoRoute(
      path: '/profile/settings',
      builder: (context, state) => const SettingsScreen(),
    ),
    GoRoute(
      path: '/profile/edit-name',
      builder: (context, state) => const EditNameScreen(),
    ),
    GoRoute(
      path: '/profile/edit-phone',
      builder: (context, state) => const EditPhoneScreen(),
    ),
    GoRoute(
      path: '/profile/change-password',
      builder: (context, state) => const ChangePasswordScreen(),
    ),
    GoRoute(
      path: '/profile/link-email',
      builder: (context, state) => const LinkEmailScreen(),
    ),
  ],
);

class LipsLinkApp extends ConsumerWidget {
  const LipsLinkApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'LipsLink',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      routerConfig: _router,
    );
  }
}