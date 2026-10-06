import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../db/database_helper.dart';
import '../db/vault_queries.dart';


/// Paths manifest lo relative ga untayi, so restore e phone lo aina pani chestundi.
class BackupService {
  Future<Directory> _vaultSub(String sub) async {
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, 'Vault', sub));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<File> createBackup({void Function(int done, int total)? onProgress}) async {
    final items = await DatabaseHelper.instance.fetchAll();
    final tmp = await getTemporaryDirectory();
    final stamp = DateTime.now().toIso8601String().split('.').first.replaceAll(':', '-');
    final zip = File(p.join(tmp.path, 'vault_backup_$stamp.zip'));
    if (await zip.exists()) await zip.delete();

    final enc = ZipFileEncoder()..create(zip.path);
    final rows = <Map<String, dynamic>>[];
    var n = 0;

    for (final i in items) {
      final media = File(i.encryptedPath);
      if (!await media.exists()) continue; // missing file skip

      // level 0 = store only. Photos already compressed, so this is much faster.
      await enc.addFile(media, 'media/${p.basename(media.path)}', 0);

      String? thumbName;
      if (i.thumbnailPath != null && i.thumbnailPath != i.encryptedPath) {
        final t = File(i.thumbnailPath!);
        if (await t.exists()) {
          thumbName = p.basename(t.path);
          await enc.addFile(t, 'thumbs/$thumbName', 0);
        }
      }

      rows.add({
        'originalName': i.originalName,
        'media': p.basename(media.path),
        'thumb': thumbName,
        'type': i.type,
        'albumName': i.albumName,
        'addedDate': i.addedDate,
        'isDeleted': i.isDeleted,
      });
      onProgress?.call(++n, items.length);
    }

    final mf = File(p.join(tmp.path, 'manifest.json'));
    await mf.writeAsString(jsonEncode({'version': 1, 'items': rows}));
    await enc.addFile(mf, 'manifest.json');
    enc.close();
    await mf.delete();
    return zip;
  }

  /// Returns number of restored items. Already-existing files are skipped (no duplicates).
  Future<int> restore(File zip) async {
    final tmp = await getTemporaryDirectory();
    final work = Directory(p.join(tmp.path, 'restore_tmp'));
    if (await work.exists()) await work.delete(recursive: true);
    await work.create(recursive: true);

    try {
      await extractFileToDisk(zip.path, work.path);
      final mf = File(p.join(work.path, 'manifest.json'));
      if (!await mf.exists()) throw Exception('Idi valid vault backup kaadu');

      final data = jsonDecode(await mf.readAsString()) as Map<String, dynamic>;
      final mediaDir = await _vaultSub('media');
      final thumbDir = await _vaultSub('thumbs');
      var restored = 0;

      for (final r in (data['items'] as List).cast<Map<String, dynamic>>()) {
        // basename = path traversal nunchi protect
        final mediaName = p.basename(r['media'] as String);
        final src = File(p.join(work.path, 'media', mediaName));
        if (!await src.exists()) continue;

        final destPath = p.join(mediaDir.path, mediaName);
        if (await File(destPath).exists()) continue; // already in vault

        await _move(src, destPath);

        String? thumbPath;
        final tn = r['thumb'] as String?;
        if (tn != null) {
          final ts = File(p.join(work.path, 'thumbs', p.basename(tn)));
          if (await ts.exists()) {
            thumbPath = p.join(thumbDir.path, p.basename(tn));
            await _move(ts, thumbPath);
          }
        }

        await DatabaseHelper.instance.insertItem({
          'originalName': r['originalName'],
          'encryptedPath': destPath,
          'thumbnailPath': thumbPath,
          'type': r['type'],
          'albumName': r['albumName'],
          'addedDate': r['addedDate'],
          'isDeleted': r['isDeleted'] ?? 0,
        });
        restored++;
      }
      return restored;
    } finally {
      if (await work.exists()) await work.delete(recursive: true);
    }
  }

  Future<void> _move(File src, String dest) async {
    try {
      await src.rename(dest);
    } catch (_) {
      await src.copy(dest); // different filesystem fallback
      await src.delete();
    }
  }
}