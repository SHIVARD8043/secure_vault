import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart';
export 'vault_queries.dart'; 
import 'package:sqflite/sqflite.dart';
import 'vault_item_model.dart';

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
    if (Platform.isLinux || Platform.isWindows) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: _createDB,
        onUpgrade: _upgradeDB,
      ),
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
        isDeleted INTEGER NOT NULL DEFAULT 0,
        takenMs INTEGER,
        modifiedMs INTEGER
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_album ON vault_items (albumName)',
    );

    // Separate table for albums
    await db.execute('''
      CREATE TABLE vault_albums (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        albumName TEXT NOT NULL UNIQUE,
        createdDate TEXT NOT NULL
      )
    ''');
  }

  Future _upgradeDB(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE vault_items ADD COLUMN takenMs INTEGER',
      );

      await db.execute(
        'ALTER TABLE vault_items ADD COLUMN modifiedMs INTEGER',
      );
    }

    if (oldVersion < 3) {
      // Create separate albums table
      await db.execute('''
        CREATE TABLE vault_albums (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          albumName TEXT NOT NULL UNIQUE,
          createdDate TEXT NOT NULL
        )
      ''');

      // Migrate existing album names, including albums
      // whose files are currently in the trash.
      await db.execute('''
        INSERT OR IGNORE INTO vault_albums (albumName, createdDate)
        SELECT albumName, MIN(addedDate)
        FROM vault_items
        WHERE TRIM(albumName) != ''
        GROUP BY albumName
      ''');
    }
  }

  Future<int> insertItem(Map<String, dynamic> item) async {
    final db = await instance.database;

    final albumName = (item['albumName'] as String).trim();

    // Ensure the album record exists before adding a file.
    await db.insert(
      'vault_albums',
      {
        'albumName': albumName,
        'createdDate': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    return await db.insert(
      'vault_items',
      item,
    );
  }

  Future<List<VaultItem>> fetchAll() async {
    final db = await database;

    final rows = await db.query(
      'vault_items',
      orderBy: 'id ASC',
    );

    return rows.map((row) => VaultItem.fromMap(row)).toList();
  }
}