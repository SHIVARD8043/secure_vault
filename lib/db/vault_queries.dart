import 'database_helper.dart';
import 'vault_item_model.dart';
import 'package:sqflite/sqflite.dart';

const _table = 'vault_items';

extension VaultQueries on DatabaseHelper {
  Future<List<Map<String, dynamic>>> fetchAlbums() async {
    final db = await database;

    return db.rawQuery('''
      SELECT
        a.albumName AS albumName,

        COUNT(v.id) AS cnt,

        (
          SELECT COALESCE(v2.thumbnailPath, v2.encryptedPath)
          FROM vault_items v2
          WHERE v2.albumName = a.albumName
            AND v2.isDeleted = 0
            AND v2.type != 'folder'
            AND v2.type != 'audio'
          ORDER BY v2.id DESC
          LIMIT 1
        ) AS cover

      FROM vault_albums a

      LEFT JOIN vault_items v
        ON v.albumName = a.albumName
        AND v.isDeleted = 0
        AND v.type != 'folder'

      GROUP BY a.id, a.albumName

      ORDER BY a.id DESC
    ''');
  }

  Future<void> createAlbum(String name) async {
    final albumName = name.trim();

    if (albumName.isEmpty) {
      throw ArgumentError('Album name cannot be empty');
    }

    final db = await database;

    await db.insert(
      'vault_albums',
      {
        'albumName': albumName,
        'createdDate': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<VaultItem>> fetchByAlbum(String album) async {
    final db = await database;
    final rows = await db.query(_table,
        where: 'albumName = ? AND isDeleted = 0 AND type != ?',
        whereArgs: [album, 'folder'],
        orderBy: 'id DESC');
    // 👈 ఇక్కడ డైరెక్ట్ గా మోడల్ లోని fromMap వాడుతున్నావ్, సూపర్!
    return rows.map(VaultItem.fromMap).toList();
  }

  Future<List<VaultItem>> fetchTrash() async {
    final db = await database;
    final rows = await db.query(_table, where: 'isDeleted = 1', orderBy: 'id DESC');
    return rows.map(VaultItem.fromMap).toList();
  }

  String _in(List<int> ids) => List.filled(ids.length, '?').join(',');

  Future<void> setDeleted(List<int> ids, bool deleted) async {
    if (ids.isEmpty) return;
    final db = await database;
    await db.update(_table, {'isDeleted': deleted ? 1 : 0},
        where: 'id IN (${_in(ids)})', whereArgs: ids);
  }

  Future<void> moveToAlbum(List<int> ids, String album) async {
    if (ids.isEmpty) return;
    final db = await database;
    await db.update(_table, {'albumName': album},
        where: 'id IN (${_in(ids)})', whereArgs: ids);
  }

  Future<void> removeRows(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    await db.delete(_table, where: 'id IN (${_in(ids)})', whereArgs: ids);
  }  
}