import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'app/app.dart';
import 'shared/models/phrase_model.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  Hive.registerAdapter(PhraseModelAdapter());
  await Hive.openBox<PhraseModel>('phrases');
  await Hive.openBox('userBox');

  runApp(
    const ProviderScope(
      child: LipsLinkApp(),
    ),
  );
}
