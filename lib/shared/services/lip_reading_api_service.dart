import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Service สำหรับเชื่อมต่อกับ LipsLink API Server
/// ส่ง lip frames ไปให้โมเดล AI อ่านปากแล้วรับข้อความกลับมา
class LipReadingApiService {
  // 🔧 กำหนด URL ผ่าน --dart-define=API_BASE_URL=... ตอน build/run
  // ไม่ระบุ = ใช้ค่า default ด้านล่าง (Android emulator loopback สำหรับ dev)
  //
  // ตัวอย่างรัน dev กับเครื่องจริงในวง LAN เดียวกัน:
  //   flutter run --dart-define=API_BASE_URL=http://192.168.1.100:8000
  // ตัวอย่าง build production หลัง deploy ขึ้น Render:
  //   flutter build apk --dart-define=API_BASE_URL=https://lipslink-api.onrender.com
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );

  static const Duration _timeout = Duration(seconds: 30);

  /// เช็กว่า Server พร้อมใช้งานหรือไม่
  static Future<bool> checkHealth() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/health'))
          .timeout(_timeout);
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// ส่งภาพปากไปให้โมเดล VocaLip ทำนายว่าเป็นคำใดใน 44 คำ
  ///
  /// [frames] ภาพปากสี PNG ขนาด 112x112 เรียงตามเวลา ส่งมากี่เฟรมก็ได้ —
  /// server จะเลือก/เติมให้เหลือ 16 เฟรมตามที่โมเดลรับเอง
  ///
  /// โมเดลนี้คืน "คำเดียว" ต่อหนึ่งคลิป ไม่ใช่ข้อความอิสระ และบังคับเลือก 1 ใน
  /// 44 คำเสมอแม้ผู้ใช้พูดคำนอกชุด จึงควรดู [WordPrediction.lowConfidence] ด้วย
  static Future<WordPrediction?> predictWord(
    List<Uint8List> frames, {
    int topK = 3,
  }) async {
    if (frames.isEmpty) return null;

    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/predict_word'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'frames': frames.map(base64Encode).toList(),
              'top_k': topK,
            }),
          )
          .timeout(_timeout);

      if (response.statusCode != 200) {
        debugPrint('❌ predict_word ${response.statusCode}: ${response.body}');
        return null;
      }

      // ต้อง decode เป็น UTF-8 เอง — FastAPI ไม่ได้ใส่ charset มาใน
      // Content-Type และ package:http จะ fallback ไปเป็น latin1 ทำให้คำไทย
      // กลายเป็นตัวอักษรขยะโดยไม่มี error ฟ้อง
      final data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return WordPrediction.fromJson(data);
    } catch (e) {
      debugPrint('❌ predict_word failed: $e');
      return null;
    }
  }

  /// ดูรายชื่อโมเดลที่มีบน Server
  static Future<Map<String, dynamic>?> getModels() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/models'))
          .timeout(_timeout);

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return null;
    } catch (e) {
      return null;
    }
  }
}

/// คำที่โมเดลเดาได้หนึ่งตัวเลือก พร้อมความมั่นใจ
class WordCandidate {
  final String word;
  final double confidence;

  const WordCandidate({required this.word, required this.confidence});

  factory WordCandidate.fromJson(Map<String, dynamic> json) => WordCandidate(
        word: json['word'] as String? ?? '',
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      );

  @override
  String toString() => '$word ${(confidence * 100).toStringAsFixed(1)}%';
}

/// ผลลัพธ์จากโมเดลทำนายคำ
class WordPrediction {
  final String word;
  final double confidence;

  /// ตัวเลือกอันดับต้นๆ เรียงจากมั่นใจที่สุด ตัวแรกคือตัวเดียวกับ [word]
  final List<WordCandidate> topK;
  final double processingTimeMs;
  final int framesUsed;

  /// server ตั้งธงนี้เมื่อความมั่นใจต่ำกว่าเกณฑ์ ไม่ได้กรองผลทิ้ง —
  /// ฝั่งแอปเป็นคนตัดสินใจเองว่าจะแสดงผลนั้นหรือไม่
  final bool lowConfidence;

  const WordPrediction({
    required this.word,
    required this.confidence,
    required this.topK,
    required this.processingTimeMs,
    required this.framesUsed,
    required this.lowConfidence,
  });

  factory WordPrediction.fromJson(Map<String, dynamic> json) => WordPrediction(
        word: json['word'] as String? ?? '',
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
        topK: (json['top_k'] as List?)
                ?.map((e) => WordCandidate.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        processingTimeMs:
            (json['processing_time_ms'] as num?)?.toDouble() ?? 0.0,
        framesUsed: (json['num_frames_used'] as num?)?.toInt() ?? 0,
        lowConfidence: json['low_confidence'] as bool? ?? false,
      );

  @override
  String toString() =>
      '${topK.join(' / ')} (${processingTimeMs.toStringAsFixed(0)}ms, '
      '$framesUsed frames)';
}
