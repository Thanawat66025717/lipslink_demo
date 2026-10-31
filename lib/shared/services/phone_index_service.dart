import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// ตาราง phones/{เบอร์} → { uid, email } สำหรับล็อกอินด้วยเบอร์โทร
///
/// users/{uid} อ่านได้เฉพาะเจ้าของ หน้า login ที่ยังไม่ได้ล็อกอินจึงค้นเบอร์ใน users ไม่ได้
/// rules ให้ใครก็ get ทีละเบอร์ได้ แต่ list ทั้งตารางไม่ได้ และแก้ได้เฉพาะ uid เจ้าของเบอร์
class PhoneIndexService {
  static final _db = FirebaseFirestore.instance;
  static final _phones = _db.collection('phones');

  /// เก็บแต่ตัวเลข ให้ "081-234-5678" กับ "0812345678" เป็น doc เดียวกัน
  static String normalize(String phone) => phone.replaceAll(RegExp(r'[^0-9]'), '');

  /// อีเมลของบัญชีที่ผูกกับเบอร์นี้ หรือ null ถ้าไม่มี
  static Future<String?> emailFor(String phone) async {
    final key = normalize(phone);
    if (key.isEmpty) return null;
    final doc = await _phones.doc(key).get();
    final email = doc.data()?['email'] as String?;
    return (email == null || email.isEmpty) ? null : email;
  }

  /// true ถ้าเบอร์นี้เป็นของบัญชีอื่นที่ไม่ใช่ uid (uid = null ตอนสมัครใหม่)
  static Future<bool> isTakenByOther(String phone, String? uid) async {
    final key = normalize(phone);
    if (key.isEmpty) return false;
    final doc = await _phones.doc(key).get();
    return doc.exists && doc.data()?['uid'] != uid;
  }

  static Future<void> claim(String uid, String email, String phone) async {
    final key = normalize(phone);
    if (key.isEmpty) return;
    await _phones.doc(key).set({'uid': uid, 'email': email});
  }

  /// เปลี่ยนเบอร์ใน users/{uid} และย้าย phones/{เบอร์เก่า} → phones/{เบอร์ใหม่} ใน batch เดียว
  static Future<void> changePhone(User user, String newPhone) async {
    final userRef = _db.collection('users').doc(user.uid);
    final data = (await userRef.get()).data() ?? {};
    final oldKey = normalize(data['phone'] as String? ?? '');
    final newKey = normalize(newPhone);

    final batch = _db.batch()..update(userRef, {'phone': newPhone});
    if (oldKey.isNotEmpty && oldKey != newKey) {
      // ลบได้เฉพาะ doc ที่มีอยู่และเป็นของเรา ไม่งั้น rules ปฏิเสธทั้ง batch
      final old = await _phones.doc(oldKey).get();
      if (old.data()?['uid'] == user.uid) batch.delete(old.reference);
    }
    if (newKey.isNotEmpty) {
      batch.set(_phones.doc(newKey), {
        'uid': user.uid,
        'email': data['email'] as String? ?? user.email ?? '',
      });
    }
    await batch.commit();
  }

  /// ให้บัญชีที่สมัครก่อนมีตารางนี้ (หรือเพิ่งเชื่อมอีเมลใหม่) มีแถวใน phones ที่อีเมลตรงกับ users/{uid}
  /// ล้มเหลวก็ไม่ขวางการล็อกอิน แค่ล็อกอินด้วยเบอร์ยังไม่ได้
  static Future<void> ensureIndexed(User user) async {
    try {
      final data = (await _db.collection('users').doc(user.uid).get()).data() ?? {};
      final phone = data['phone'] as String? ?? '';
      final key = normalize(phone);
      if (key.isEmpty) return;
      final email = data['email'] as String? ?? user.email ?? '';
      final doc = await _phones.doc(key).get();
      if (!doc.exists || (doc.data()?['uid'] == user.uid && doc.data()?['email'] != email)) {
        await claim(user.uid, email, phone);
      }
    } catch (e) {
      debugPrint('ensureIndexed ไม่สำเร็จ: $e');
    }
  }
}
