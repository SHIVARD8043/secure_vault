import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../db/database_helper.dart';

class BackupService {
  Future<Directory> _vaultSub(String sub) async {
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, 'Vault', sub));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  // ─── 1. CREATE ZIP BACKUP (Temporarily in Cache) ───
  Future<File> createBackup({String? albumName, void Function(int done, int total)? onProgress}) async {
    final allItems = await DatabaseHelper.instance.fetchAll();
    final items = albumName != null 
        ? allItems.where((i) => i.albumName == albumName).toList()
        : allItems;

    final tmp = await getTemporaryDirectory();
    final stamp = DateTime.now().toIso8601String().split('.').first.replaceAll(':', '-');
    final zip = File(p.join(tmp.path, 'vault_backup_$stamp.zip'));
    if (await zip.exists()) await zip.delete();

    final enc = ZipFileEncoder()..create(zip.path);
    final rows = <Map<String, dynamic>>[];
    var n = 0;

    for (final i in items) {
      final media = File(i.encryptedPath);
      if (!await media.exists()) continue; // ఫైల్ లేకపోతే స్కిప్

      // కుదించిన ఫైల్స్ కాబట్టి level 0 (ఫాస్ట్) వాడుతున్నాం
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

  // ─── 2. EXPORT TO DOWNLOADS (Public Folder) ───
  Future<String?> exportToDownloads(File backupZip) async {
    try {
      // ఆండ్రాయిడ్ స్టోరేజ్ పర్మిషన్స్ చెక్ చేస్తున్నాం
      if (Platform.isAndroid) {
        final status = await Permission.storage.request();
        if (!status.isGranted && !await Permission.manageExternalStorage.isGranted) {
          return null; 
        }
      }

      // ఆండ్రాయిడ్ అఫీషియల్ డౌన్‌లోడ్స్ ఫోల్డర్ పాత్
      final downloadDir = Directory('/storage/emulated/0/Download');
      if (!await downloadDir.exists()) await downloadDir.create(recursive: true);

      final stamp = DateTime.now().toIso8601String().split('.').first.replaceAll(':', '-');
      final fileName = 'Vault_Backup_$stamp.zip';
      final destPath = p.join(downloadDir.path, fileName);

      // ఫైల్ ని పబ్లిక్ ఫోల్డర్ కి కాపీ చేసి, ప్రైవేట్ ఫైల్ ని డిలీట్ చేస్తున్నాం (స్టోరేజ్ సేవ్ అవ్వడానికి)
      await backupZip.copy(destPath);
      if (await backupZip.exists()) await backupZip.delete();

      return destPath;
    } catch (e) {
      print('Export Error: $e');
      return null;
    }
  }

  // ─── 3. RESTORE FROM ZIP ───
  Future<int> restore(File zip) async {
    final tmp = await getTemporaryDirectory();
    final work = Directory(p.join(tmp.path, 'restore_tmp'));
    if (await work.exists()) await work.delete(recursive: true);
    await work.create(recursive: true);

    try {
      await extractFileToDisk(zip.path, work.path);
      final mf = File(p.join(work.path, 'manifest.json'));
      if (!await mf.exists()) throw Exception('ఇది కరెక్ట్ బ్యాకప్ ఫైల్ కాదు!');

      final data = jsonDecode(await mf.readAsString()) as Map<String, dynamic>;
      final mediaDir = await _vaultSub('media');
      final thumbDir = await _vaultSub('thumbs');
      var restored = 0;

      for (final r in (data['items'] as List).cast<Map<String, dynamic>>()) {
        final mediaName = p.basename(r['media'] as String);
        final src = File(p.join(work.path, 'media', mediaName));
        if (!await src.exists()) continue;

        final destPath = p.join(mediaDir.path, mediaName);
        if (await File(destPath).exists()) continue; // ఆల్రెడీ ఉంటే స్కిప్

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
      // పని అయిపోయాక టెంపరరీ ఫైల్స్ క్లీన్ చేస్తున్నాం
      if (await work.exists()) await work.delete(recursive: true);
    }
  }

  Future<void> _move(File src, String dest) async {
    try {
      await src.rename(dest);
    } catch (_) {
      await src.copy(dest);
      await src.delete();
    }
  }
}