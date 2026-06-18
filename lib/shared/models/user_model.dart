class UserModel {
  final String id;
  final String name;
  final String email;
  final String phone;
  final String? profileImagePath;
  final DateTime? dateOfBirth;
  final DateTime createdAt;

  UserModel({
    required this.id,
    required this.name,
    required this.email,
    required this.phone,
    this.profileImagePath,
    this.dateOfBirth,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'email': email,
      'phone': phone,
      'profileImagePath': profileImagePath,
      'dateOfBirth': dateOfBirth?.toIso8601String(),
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory UserModel.fromMap(Map<String, dynamic> map) {
    return UserModel(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      email: map['email'] ?? '',
      phone: map['phone'] ?? '',
      profileImagePath: map['profileImagePath'],
      dateOfBirth: map['dateOfBirth'] != null ? DateTime.parse(map['dateOfBirth']) : null,
      createdAt: DateTime.parse(map['createdAt'] ?? DateTime.now().toIso8601String()),
    );
  }

  UserModel copyWith({
    String? name,
    String? email,
    String? phone,
    String? profileImagePath,
    DateTime? dateOfBirth,
  }) {
    return UserModel(
      id: id,
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      profileImagePath: profileImagePath ?? this.profileImagePath,
      dateOfBirth: dateOfBirth ?? this.dateOfBirth,
      createdAt: createdAt,
    );
  }
}
