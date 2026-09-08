import 'dart:convert';
import 'dart:typed_data';
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

  /// ส่ง lip frames ไปให้โมเดลอ่านปาก (Model 1: lip only)
  ///
  /// [frames] - List ของภาพปาก (grayscale bytes)
  /// Returns: PredictionResult หรือ null ถ้าเกิดข้อผิดพลาด
  static Future<PredictionResult?> predictFromFrames(
    List<Uint8List> frames, {
    String model = 'model1',
    List<Uint8List>? faceFrames,
  }) async {
    if (frames.isEmpty) return null;

    try {
      // แปลง frames เป็น base64
      final base64Frames = frames.map((f) => base64Encode(f)).toList();

      // สร้าง request body
      final Map<String, dynamic> body = {
        'frames': base64Frames,
        'model': model,
      };

      // ถ้ามี face frames (สำหรับ model2)
      if (faceFrames != null && faceFrames.isNotEmpty) {
        body['face_frames'] = faceFrames.map((f) => base64Encode(f)).toList();
      }

      final response = await http
          .post(
            Uri.parse('$_baseUrl/predict'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return PredictionResult(
          text: data['text'] ?? '',
          confidence: (data['confidence'] ?? 0.0).toDouble(),
          modelUsed: data['model_used'] ?? model,
          processingTimeMs: (data['processing_time_ms'] ?? 0.0).toDouble(),
          numFrames: data['num_frames'] ?? frames.length,
        );
      } else {
        final error = jsonDecode(response.body);
        print('❌ API Error: ${error['detail']}');
        return null;
      }
    } catch (e) {
      print('❌ Network Error: $e');
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

/// ผลลัพธ์การ prediction
class PredictionResult {
  final String text;
  final double confidence;
  final String modelUsed;
  final double processingTimeMs;
  final int numFrames;

  PredictionResult({
    required this.text,
    required this.confidence,
    required this.modelUsed,
    required this.processingTimeMs,
    required this.numFrames,
  });

  @override
  String toString() =>
      'PredictionResult(text: "$text", confidence: ${(confidence * 100).toStringAsFixed(1)}%, time: ${processingTimeMs.toStringAsFixed(0)}ms)';
}
