import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import '../db/database_helper.dart';
import '../db/vault_item_model.dart';
import '../db/vault_queries.dart';
import 'package:flutter/foundation.dart';

class VaultService {
  static final _rand = Random();

  Future<Directory> _dir(String sub) async {
    final base = await getApplicationSupportDirectory(); // sandboxed, not visible in file manager
    final d = Directory(p.join(base.path, 'Vault', sub));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  // ఇక్కడ కొత్తగా {bool trash = false} అని యాడ్ చేశాం 
  Future<bool> hideAsset(AssetEntity asset, String album, {bool trash = false}) async {
    try {
      final src = await asset.originFile;
      if (src == null) return false;

      final media = await _dir('media');
      final thumbs = await _dir('thumbs');
      final id = '${DateTime.now().microsecondsSinceEpoch}_${_rand.nextInt(9999)}';
      final dest = p.join(media.path, '$id${p.extension(src.path)}');

      await src.copy(dest); 
      if (await File(dest).length() != await src.length()) {
        await File(dest).delete();
        return false;
      }

      String? thumbPath;
      final bytes = await asset.thumbnailDataWithSize(const ThumbnailSize(400, 400), quality: 80);
      if (bytes != null) {
        thumbPath = p.join(thumbs.path, '$id.jpg');
        await File(thumbPath).writeAsBytes(bytes);
      }

      final item = VaultItem(
        originalName: p.basename(src.path),
        encryptedPath: dest,
        thumbnailPath: thumbPath,
        type: asset.type == AssetType.video ? 'video' : 'image',
        albumName: album,
        addedDate: asset.createDateTime.toIso8601String(),
        // 👈 ఇక్కడ డైరెక్ట్ గా కండిషన్ పెట్టేశాం 
        isDeleted: trash ? 1 : 0, 
      );
      await DatabaseHelper.instance.insertItem(item.toMap());
      return true;
    } catch (e) {
      debugPrint('Hide Error: $e');
      return false;
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

  /// Puts the photo/video back in the phone gallery, then removes it from the vault.
  Future<void> exportToGallery(List<VaultItem> items, {bool removeFromVault = true}) async {
    for (final i in items) {
      if (i.type == 'video') {
        await PhotoManager.editor.saveVideo(File(i.encryptedPath), title: i.originalName);
      } else {
        await PhotoManager.editor.saveImageWithPath(i.encryptedPath, title: i.originalName);
      }
    }
    if (removeFromVault) await deleteForever(items);
  }
}
