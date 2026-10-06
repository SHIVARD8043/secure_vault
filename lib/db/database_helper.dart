import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('vault.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    // Linux/Windows lo FFI init
    if (Platform.isLinux || Platform.isWindows) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 1, onCreate: _createDB),
    );
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE vault_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        originalName TEXT NOT NULL,
        encryptedPath TEXT NOT NULL,
        thumbnailPath TEXT,
        type TEXT NOT NULL,
        albumName TEXT NOT NULL,
        addedDate TEXT NOT NULL,
        isDeleted INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('CREATE INDEX idx_album ON vault_items (albumName)');
  }

  Future<int> insertItem(Map<String, dynamic> item) async {
    final db = await instance.database;
    return await db.insert('vault_items', item);
  }
}