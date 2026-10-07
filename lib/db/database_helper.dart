import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart';
import 'vault_item_model.dart'; // 👈 VaultItem కోసం ఈ ఇంపోర్ట్ యాడ్ చేశాం

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

  // ════════════════════════════════════════════════════════════════════
  //  కొత్తగా యాడ్ చేసిన డేటాబేస్ ఫంక్షన్స్ ఇవే మావా! 🚀
  // ════════════════════════════════════════════════════════════════════

  // 1. వాల్ట్ లో ఉన్న అన్ని ఐటెమ్స్ ని తీసుకురావడానికి
  Future<List<VaultItem>> fetchAll() async {
    final db = await instance.database;
    final maps = await db.query('vault_items');
    return maps.map((map) => VaultItem.fromMap(map)).toList();
  }

  // 2. ఆల్బమ్ పేర్లని తీసుకురావడానికి
  Future<List<Map<String, dynamic>>> fetchAlbums() async {
    final db = await instance.database;
    return await db.rawQuery('SELECT DISTINCT albumName FROM vault_items');
  }

  // 3. ట్రాష్ (Bin) లోకి వేయడానికి లేదా రిస్టోర్ చేయడానికి
  Future<void> setDeleted(List<int> ids, bool isDeleted) async {
    if (ids.isEmpty) return;
    final db = await instance.database;
    final placeholders = List.filled(ids.length, '?').join(',');
    
    await db.rawUpdate(
      'UPDATE vault_items SET isDeleted = ? WHERE id IN ($placeholders)',
      [isDeleted ? 1 : 0, ...ids]
    );
  }

  // 4. ట్రాష్ లోంచి శాశ్వతంగా (Permanently) డిలీట్ చేయడానికి
  Future<void> removeRows(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await instance.database;
    final placeholders = List.filled(ids.length, '?').join(',');
    
    await db.delete(
      'vault_items', 
      where: 'id IN ($placeholders)', 
      whereArgs: ids
    );
  }
}