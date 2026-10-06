import 'database_helper.dart';
import 'vault_item_model.dart';

const _table = 'vault_items'; // change if your table name differs

VaultItem _fromMap(Map<String, dynamic> e) => VaultItem(
      id: e['id'],
      originalName: e['originalName'],
      encryptedPath: e['encryptedPath'],
      thumbnailPath: e['thumbnailPath'],
      type: e['type'],
      albumName: e['albumName'],
      addedDate: e['addedDate'],
      isDeleted: e['isDeleted'],
    );

extension VaultQueries on DatabaseHelper {
  Future<List<Map<String, dynamic>>> fetchAlbums() async {
    final db = await database;
    return db.rawQuery('''
      SELECT v.albumName AS albumName, COUNT(*) AS cnt,
        (SELECT COALESCE(v2.thumbnailPath, v2.encryptedPath) FROM $_table v2
          WHERE v2.albumName = v.albumName AND v2.isDeleted = 0
          ORDER BY v2.id DESC LIMIT 1) AS cover
      FROM $_table v WHERE v.isDeleted = 0
      GROUP BY v.albumName ORDER BY MAX(v.id) DESC''');
  }

  Future<List<VaultItem>> fetchByAlbum(String album) async {
    final db = await database;
    final rows = await db.query(_table,
        where: 'albumName = ? AND isDeleted = 0', whereArgs: [album], orderBy: 'id DESC');
    return rows.map(_fromMap).toList();
  }

  Future<List<VaultItem>> fetchTrash() async {
    final db = await database;
    final rows = await db.query(_table, where: 'isDeleted = 1', orderBy: 'id DESC');
    return rows.map(_fromMap).toList();
  }

  String _in(List<int> ids) => List.filled(ids.length, '?').join(',');

  Future<void> setDeleted(List<int> ids, bool deleted) async {
    final db = await database;
    await db.update(_table, {'isDeleted': deleted ? 1 : 0},
        where: 'id IN (${_in(ids)})', whereArgs: ids);
  }

  Future<void> moveToAlbum(List<int> ids, String album) async {
    final db = await database;
    await db.update(_table, {'albumName': album},
        where: 'id IN (${_in(ids)})', whereArgs: ids);
  }

  Future<void> removeRows(List<int> ids) async {
    final db = await database;
    await db.delete(_table, where: 'id IN (${_in(ids)})', whereArgs: ids);
  }
    Future<List<VaultItem>> fetchAll() async {
    final db = await database;
    final rows = await db.query(_table, orderBy: 'id ASC'); // trash items kuda
    return rows.map(_fromMap).toList();
  }
}