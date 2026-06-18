import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import '../models/user_model.dart';

class StorageService {
  static const _usersKey = 'registered_users';
  static const _currentUserKey = 'current_user';
  static const _passwordsKey = 'user_passwords';

  // ─── Auth ─────────────────────────────────────────────
  static Future<bool> register({
    required String name,
    required String email,
    required String phone,
    required String password,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final usersJson = prefs.getString(_usersKey);
    final users = usersJson != null
        ? (jsonDecode(usersJson) as List).cast<Map<String, dynamic>>()
        : <Map<String, dynamic>>[];

    // Check duplicate email
    if (users.any((u) => u['email'] == email)) return false;

    final user = UserModel(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      email: email,
      phone: phone,
      createdAt: DateTime.now(),
    );
    users.add(user.toMap());
    await prefs.setString(_usersKey, jsonEncode(users));

    // Save hashed password
    final passwords = jsonDecode(prefs.getString(_passwordsKey) ?? '{}')
        as Map<String, dynamic>;
    passwords[email] = _hashPassword(password);
    await prefs.setString(_passwordsKey, jsonEncode(passwords));

    // Auto login
    await prefs.setString(_currentUserKey, jsonEncode(user.toMap()));
    return true;
  }

  static Future<UserModel?> login(String email, String password) async {
    final prefs = await SharedPreferences.getInstance();
    final usersJson = prefs.getString(_usersKey);
    if (usersJson == null) return null;

    final users = (jsonDecode(usersJson) as List).cast<Map<String, dynamic>>();
    final passwords = jsonDecode(prefs.getString(_passwordsKey) ?? '{}')
        as Map<String, dynamic>;

    final userMap = users.cast<Map<String, dynamic>?>().firstWhere(
          (u) => u?['email'] == email,
          orElse: () => null,
        );
    if (userMap == null) return null;

    final hashed = _hashPassword(password);
    if (passwords[email] != hashed) return null;

    final user = UserModel.fromMap(userMap);
    await prefs.setString(_currentUserKey, jsonEncode(user.toMap()));
    return user;
  }

  static Future<UserModel?> getCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_currentUserKey);
    if (json == null) return null;
    return UserModel.fromMap(jsonDecode(json) as Map<String, dynamic>);
  }

  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_currentUserKey);
  }

  // ─── Profile Update ───────────────────────────────────
  static Future<void> updateUser(UserModel user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_currentUserKey, jsonEncode(user.toMap()));

    // Update in users list too
    final usersJson = prefs.getString(_usersKey);
    if (usersJson != null) {
      final users =
          (jsonDecode(usersJson) as List).cast<Map<String, dynamic>>();
      final idx = users.indexWhere((u) => u['id'] == user.id);
      if (idx != -1) {
        users[idx] = user.toMap();
        await prefs.setString(_usersKey, jsonEncode(users));
      }
    }
  }

  static Future<bool> changePassword(
      String email, String oldPassword, String newPassword) async {
    final prefs = await SharedPreferences.getInstance();
    final passwords = jsonDecode(prefs.getString(_passwordsKey) ?? '{}')
        as Map<String, dynamic>;
    if (passwords[email] != _hashPassword(oldPassword)) return false;
    passwords[email] = _hashPassword(newPassword);
    await prefs.setString(_passwordsKey, jsonEncode(passwords));
    return true;
  }

  // ─── Helpers ──────────────────────────────────────────
  static String _hashPassword(String password) {
    final bytes = utf8.encode(password + 'lipslink_salt_2025');
    return sha256.convert(bytes).toString();
  }
}
