import 'package:hive/hive.dart';

part 'phrase_model.g.dart';

@HiveType(typeId: 0)
class PhraseModel extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String text;

  @HiveField(2)
  String emotion;

  @HiveField(3)
  DateTime createdAt;

  @HiveField(4)
  int usageCount;

  @HiveField(5)
  bool isFavorite;

  PhraseModel({
    required this.id,
    required this.text,
    required this.emotion,
    required this.createdAt,
    this.usageCount = 1,
    this.isFavorite = false,
  });
}
