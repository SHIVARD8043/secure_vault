class VaultItem {
  final int? id;
  final String originalName;
  final String encryptedPath;
  final String? thumbnailPath;
  final String type;
  final String albumName;
  final String addedDate;
  final int isDeleted;

  /// Original capture time (ms since epoch). Null for items hidden before DB v2.
  final int? takenMs;

  /// Original last-modified time (ms since epoch). Null for items hidden before DB v2.
  final int? modifiedMs;

  VaultItem({
    this.id,
    required this.originalName,
    required this.encryptedPath,
    this.thumbnailPath,
    required this.type,
    required this.albumName,
    required this.addedDate,
    this.isDeleted = 0,
    this.takenMs,
    this.modifiedMs,
  });

  /// Falls back to addedDate (which held the original date in old rows).
  int get effectiveTakenMs =>
      takenMs ??
      (DateTime.tryParse(addedDate)?.millisecondsSinceEpoch ??
          DateTime.now().millisecondsSinceEpoch);

  int get effectiveModifiedMs => modifiedMs ?? effectiveTakenMs;

  factory VaultItem.fromMap(Map<String, dynamic> map) {
    return VaultItem(
      id: map['id'] as int?,
      originalName: map['originalName'] as String,
      encryptedPath: map['encryptedPath'] as String,
      thumbnailPath: map['thumbnailPath'] as String?,
      type: map['type'] as String,
      albumName: map['albumName'] as String,
      addedDate: map['addedDate'] as String,
      isDeleted: map['isDeleted'] as int,
      takenMs: map['takenMs'] as int?,
      modifiedMs: map['modifiedMs'] as int?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'originalName': originalName,
      'encryptedPath': encryptedPath,
      'thumbnailPath': thumbnailPath,
      'type': type,
      'albumName': albumName,
      'addedDate': addedDate,
      'isDeleted': isDeleted,
      'takenMs': takenMs,
      'modifiedMs': modifiedMs,
    };
  }
}