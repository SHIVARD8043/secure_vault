import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../db/database_helper.dart';

class BackupService {
  static const int _manifestVersion = 2;

  Future<Directory> _vaultSub(String sub) async {
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, 'Vault', sub));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  // ─── 1. CREATE ZIP BACKUP (temporarily in cache) ───
  Future<File> createBackup({
    String? albumName,
    void Function(int done, int total)? onProgress,
  }) async {
    final allItems = await DatabaseHelper.instance.fetchAll();
    final items = albumName != null
        ? allItems.where((i) => i.albumName == albumName).toList()
        : allItems;

    final tmp = await getTemporaryDirectory();
    final stamp = DateTime.now().toIso8601String().split('.').first.replaceAll(':', '-');
    final zipFile = File(p.join(tmp.path, 'vault_backup_$stamp.zip'));
    if (await zipFile.exists()) await zipFile.delete();

    // 👈 1. Archive object క్రియేట్ చేస్తున్నాం, దీంట్లో డేట్స్ సెట్ చేయొచ్చు
    final archive = Archive();
    final rows = <Map<String, dynamic>>[];
    var n = 0;

    for (final i in items) {
      if (i.type == 'folder') {
        rows.add({
          'originalName': i.originalName,
          'media': null,
          'rawPath': i.encryptedPath, 
          'thumb': null,
          'type': i.type,
          'albumName': i.albumName,
          'addedDate': i.addedDate,
          'isDeleted': i.isDeleted,
          'takenMs': i.takenMs,
          'modifiedMs': i.modifiedMs,
        });
        onProgress?.call(++n, items.length);
        continue;
      }

      final media = File(i.encryptedPath);
      if (!await media.exists()) continue; 

      // 👈 2. ఇక్కడే అసలైన EXIF డేట్ (takenMs) ని తీసుకుంటున్నాం
      final fallbackDate = DateTime.tryParse(i.addedDate) ?? DateTime.now();
      final modTime = i.takenMs != null ? i.takenMs! ~/ 1000 : fallbackDate.millisecondsSinceEpoch ~/ 1000;

      // 👈 3. ArchiveFile కి కచ్చితంగా lastModTime ఇవ్వాలి! అప్పుడే ఒరిజినల్ డేట్ సేవ్ అవుతుంది
      final mediaBytes = await media.readAsBytes();
      final mediaArchiveFile = ArchiveFile('media/${p.basename(media.path)}', mediaBytes.length, mediaBytes);
      mediaArchiveFile.lastModTime = modTime; 
      archive.addFile(mediaArchiveFile);

      String? thumbName;
      if (i.thumbnailPath != null && i.thumbnailPath != i.encryptedPath) {
        final t = File(i.thumbnailPath!);
        if (await t.exists()) {
          thumbName = p.basename(t.path);
          final thumbBytes = await t.readAsBytes();
          final thumbArchiveFile = ArchiveFile('thumbs/$thumbName', thumbBytes.length, thumbBytes);
          thumbArchiveFile.lastModTime = modTime;
          archive.addFile(thumbArchiveFile);
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
        'takenMs': i.takenMs,
        'modifiedMs': i.modifiedMs,
      });
      onProgress?.call(++n, items.length);
    }

    final manifestBytes = utf8.encode(jsonEncode({'version': _manifestVersion, 'items': rows}));
    final mfFile = ArchiveFile('manifest.json', manifestBytes.length, manifestBytes);
    archive.addFile(mfFile);

    // 👈 4. Zip ని ఫైల్ సిస్టమ్ కి రాస్తున్నాం
    final zipEncoder = ZipEncoder();
    final encodedZipBytes = zipEncoder.encode(archive);
    if (encodedZipBytes != null) {
      await zipFile.writeAsBytes(encodedZipBytes);
    }

    return zipFile;
  }

  // ─── 2. EXPORT TO DOWNLOADS (public folder) ───
  Future<String?> exportToDownloads(File backupZip) async {
    try {
      if (Platform.isAndroid) {
        var status = await Permission.storage.request();
        if (!status.isGranted) {
          var manageStatus = await Permission.manageExternalStorage.request();
          if (!manageStatus.isGranted) {
            debugPrint('Storage permission ivvaledu mawa!');
            return null;
          }
        }
      }

      final downloadDir = Directory('/storage/emulated/0/Download');
      if (!await downloadDir.exists()) await downloadDir.create(recursive: true);

      final stamp = DateTime.now().toIso8601String().split('.').first.replaceAll(':', '-');
      final fileName = 'Vault_Backup_$stamp.zip';
      final destPath = p.join(downloadDir.path, fileName);

      await backupZip.copy(destPath);
      if (await backupZip.exists()) await backupZip.delete();

      return destPath;
    } catch (e) {
      debugPrint('Export Error: $e');
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
      if (!await mf.exists()) throw Exception('Idi correct backup file kaadu!');

      final data = jsonDecode(await mf.readAsString()) as Map<String, dynamic>;
      final mediaDir = await _vaultSub('media');
      final thumbDir = await _vaultSub('thumbs');
      var restored = 0;

      final existing = await DatabaseHelper.instance.fetchAll();
      final existingFolders = existing
          .where((e) => e.type == 'folder')
          .map((e) => '${e.albumName}|${e.isDeleted}')
          .toSet();

      for (final r in (data['items'] as List).cast<Map<String, dynamic>>()) {
        if (r['media'] == null) {
          final key = '${r['albumName']}|${r['isDeleted'] ?? 0}';
          if (existingFolders.contains(key)) continue;

          await DatabaseHelper.instance.insertItem({
            'originalName': r['originalName'] ?? '',
            'encryptedPath': (r['rawPath'] as String?) ?? '',
            'thumbnailPath': null,
            'type': r['type'] ?? 'folder',
            'albumName': r['albumName'],
            'addedDate': r['addedDate'] ?? DateTime.now().toIso8601String(),
            'isDeleted': r['isDeleted'] ?? 0,
            'takenMs': r['takenMs'],
            'modifiedMs': r['modifiedMs'],
          });
          existingFolders.add(key);
          restored++;
          continue;
        }

        final mediaName = p.basename(r['media'] as String);
        final src = File(p.join(work.path, 'media', mediaName));
        if (!await src.exists()) continue;

        final destPath = p.join(mediaDir.path, mediaName);
        if (await File(destPath).exists()) continue; 

        await _move(src, destPath);

        // 👈 5. ఇక్కడ కూడా ఒరిజినల్ takenMs ని ఫైల్ డేట్ కి అప్లై చేస్తున్నాం
        final mm = r['takenMs'] ?? r['modifiedMs']; 
        if (mm is int) {
          try {
            await File(destPath).setLastModified(DateTime.fromMillisecondsSinceEpoch(mm));
            await File(destPath).setLastAccessed(DateTime.fromMillisecondsSinceEpoch(mm));
          } catch (_) {}
        }

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
          'takenMs': r['takenMs'], 
          'modifiedMs': r['modifiedMs'],
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
      await src.copy(dest);
      await src.delete();
    }
  }
}