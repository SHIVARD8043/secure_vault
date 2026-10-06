class VaultItem {
  int? id;
  String originalName;
  String encryptedPath;
  String? thumbnailPath;
  String type;
  String albumName;
  String addedDate;
  int isDeleted; // 0 = నార్మల్, 1 = బిన్ లో ఉంది

  VaultItem({
    this.id,
    required this.originalName,
    required this.encryptedPath,
    this.thumbnailPath,
    required this.type,
    required this.albumName,
    required this.addedDate,
    this.isDeleted = 0, // డీఫాల్ట్ గా 0
  });

  Map<String, dynamic> toMap() {
    return {
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