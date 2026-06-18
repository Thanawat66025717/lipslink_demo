// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'phrase_model.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class PhraseModelAdapter extends TypeAdapter<PhraseModel> {
  @override
  final int typeId = 0;

  @override
  PhraseModel read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PhraseModel(
      id: fields[0] as String,
      text: fields[1] as String,
      emotion: fields[2] as String,
      createdAt: fields[3] as DateTime,
      usageCount: fields[4] as int,
      isFavorite: fields[5] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, PhraseModel obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.text)
      ..writeByte(2)
      ..write(obj.emotion)
      ..writeByte(3)
      ..write(obj.createdAt)
      ..writeByte(4)
      ..write(obj.usageCount)
      ..writeByte(5)
      ..write(obj.isFavorite);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PhraseModelAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
