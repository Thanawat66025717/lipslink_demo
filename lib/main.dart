import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'app/app.dart';
import 'shared/models/phrase_model.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. ตั้งค่า Firebase ให้เสร็จก่อน
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // 2. ตั้งค่า Hive (ฐานข้อมูลออฟไลน์)
  await Hive.initFlutter();
  Hive.registerAdapter(PhraseModelAdapter());
  await Hive.openBox<PhraseModel>('phrases');
  await Hive.openBox('userBox');

  // ตั้งค่า Facebook Auth สำหรับ Web
  if (kIsWeb) {
    await FacebookAuth.i.webAndDesktopInitialize(
      appId: "2024607208180955",
      cookie: true,
      xfbml: true,
      version: "v17.0",
    );
  }

  // 3. รันแอปพลิเคชัน (เรียก runApp แค่ครั้งเดียว และใช้ LipsLinkApp ของคุณ)
  runApp(
    const ProviderScope(
      child: LipsLinkApp(),
    ),
  );
}
