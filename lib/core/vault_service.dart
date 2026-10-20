import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import '../db/database_helper.dart';
import '../db/vault_item_model.dart';
import 'package:exif/exif.dart';

class VaultService {
  static final _rand = Random();
  static const _ch = MethodChannel('vault/export');

  Future<Directory> _dir(String sub) async {
    final base = await getApplicationSupportDirectory(); // sandboxed
    final d = Directory(p.join(base.path, 'Vault', sub));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<bool> hideAsset(AssetEntity asset, String album, {bool trash = false}) async {
    try {
      final src = await asset.originFile;
      if (src == null) return false;

      final realTitle = asset.title ?? p.basename(src.path);
      final realModified = asset.modifiedDateTime;
      final realCreated = asset.createDateTime;

      // Images ki EXIF DateTimeOriginal first, fail aithe createDateTime fallback.
      int takenMs = realCreated.millisecondsSinceEpoch;
      if (asset.type == AssetType.image) {
        takenMs = await _exifTakenMs(src) ?? takenMs;
      }

      final media = await _dir('media');
      final thumbs = await _dir('thumbs');
      final id = '${DateTime.now().microsecondsSinceEpoch}_${_rand.nextInt(9999)}';

      final ext = realTitle.contains('.')
          ? '.${realTitle.split('.').last}'
          : p.extension(src.path);
      final dest = p.join(media.path, '$id$ext');
      final destFile = File(dest);

      await src.copy(dest);
      if (await destFile.length() != await src.length()) {
        await destFile.delete();
        return false;
      }

      try {
        await destFile.setLastModified(realModified);
      } catch (_) {}

      String? thumbPath;
      final bytes = await asset.thumbnailDataWithSize(const ThumbnailSize(400, 400), quality: 80);
      if (bytes != null) {
        thumbPath = p.join(thumbs.path, '$id.jpg');
        await File(thumbPath).writeAsBytes(bytes);
      }

      final item = VaultItem(
        originalName: realTitle,
        encryptedPath: dest,
        thumbnailPath: thumbPath,
        type: asset.type == AssetType.video ? 'video' : 'image',
        albumName: album,
        addedDate: DateTime.fromMillisecondsSinceEpoch(takenMs).toIso8601String(),
        isDeleted: trash ? 1 : 0,
        takenMs: takenMs,
        modifiedMs: realModified.millisecondsSinceEpoch,
      );
      await DatabaseHelper.instance.insertItem(item.toMap());
      return true;
    } catch (e) {
      debugPrint('Hide Error: $e');
      return false;
    }
  }

  /// EXIF DateTimeOriginal -> ms. Images ki matrame; fail aithe null.
  Future<int?> _exifTakenMs(File f) async {
    try {
      final tags = await readExifFromFile(f);
      final raw = (tags['EXIF DateTimeOriginal'] ??
              tags['EXIF DateTimeDigitized'] ??
              tags['Image DateTime'])
          ?.printable; // "2023:08:15 14:32:10"
      if (raw == null || raw.length < 19 || raw.startsWith('0000')) return null;
      final d = raw.substring(0, 10).replaceAll(':', '-');
      final dt = DateTime.tryParse('$d ${raw.substring(11, 19)}');
      return dt?.millisecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteForever(List<VaultItem> items) async {
    for (final i in items) {
      for (final path in {i.encryptedPath, i.thumbnailPath}) {
        if (path == null) continue;
        final f = File(path);
        if (await f.exists()) await f.delete();
      }
    }
    await DatabaseHelper.instance.removeRows(items.map((e) => e.id!).toList());
  }

  String _mimeFor(VaultItem i) {
    final guess = lookupMimeType(i.originalName) ?? lookupMimeType(i.encryptedPath);
    if (guess != null) return guess;
    switch (i.type) {
      case 'video':
        return 'video/mp4';
      case 'audio':
        return 'audio/mpeg';
      default:
        return 'image/jpeg';
    }
  }

  /// Returns the number of items that FAILED to export.
  /// Only items that were saved successfully are removed from the vault.
  Future<int> exportToGallery(List<VaultItem> items, {bool removeFromVault = true}) async {
    final done = <VaultItem>[];
    var failed = 0;

    for (final i in items) {
      try {
        final ok = await _ch.invokeMethod<bool>('save', {
          'path': i.encryptedPath,
          'name': i.originalName.isNotEmpty
              ? i.originalName
              : 'vault_${DateTime.now().millisecondsSinceEpoch}${p.extension(i.encryptedPath)}',
          'mime': _mimeFor(i),
          'takenMs': i.effectiveTakenMs,
          'modifiedMs': i.effectiveModifiedMs,
        });
        if (ok == true) {
          done.add(i);
        } else {
          failed++;
        }
      } catch (e) {
        debugPrint('Export Error: $e');
        failed++;
      }
    }

    if (removeFromVault && done.isNotEmpty) await deleteForever(done);
    return failed;
  }
}