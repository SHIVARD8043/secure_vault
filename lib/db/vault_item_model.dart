class VaultItem {
  final int? id;
  final String originalName;
  final String encryptedPath;
  final String? thumbnailPath;
  final String type;
  final String albumName;
  final String addedDate;
  final int isDeleted;

  VaultItem({
    this.id,
    required this.originalName,
    required this.encryptedPath,
    this.thumbnailPath,
    required this.type,
    required this.albumName,
    required this.addedDate,
    this.isDeleted = 0,
  });

  // డేటాబేస్ లోని Map ని VaultItem ఆబ్జెక్ట్ గా మార్చడానికి
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
    );
  }

  // VaultItem ఆబ్జెక్ట్ ని డేటాబేస్ లో సేవ్ చేయడానికి Map గా మార్చడానికి
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
    };
  }
}