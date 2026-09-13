import 'package:shared_preferences/shared_preferences.dart';

/// จำว่าผู้ใช้ดูหน้าแนะนำการใช้งานไปแล้วหรือยัง
///
/// แยกออกมาเป็นที่เดียวเพราะมีสองฝั่งที่ต้องใช้คีย์เดียวกัน — หน้า splash อ่าน
/// เพื่อตัดสินใจว่าจะพาไปหน้าไหน และหน้า onboarding เขียนตอนผู้ใช้กดเริ่มใช้งาน
/// ถ้าปล่อยให้ต่างคนต่างเขียนคีย์เอง วันหนึ่งแก้ที่เดียวแล้วลืมอีกที่จะกลายเป็น
/// หน้าแนะนำเด้งซ้ำทุกครั้งที่เปิดแอป
class OnboardingPrefs {
  static const _seenKey = 'has_seen_onboarding';

  static Future<bool> hasSeen() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_seenKey) ?? false;
  }

  static Future<void> markSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_seenKey, true);
  }
}
