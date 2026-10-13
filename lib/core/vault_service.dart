import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:flutter/foundation.dart';
import '../db/database_helper.dart';
import '../db/vault_item_model.dart';

class VaultService {
  static final _rand = Random();

  Future<Directory> _dir(String sub) async {
    final base = await getApplicationSupportDirectory(); // sandboxed, not visible in file manager
    final d = Directory(p.join(base.path, 'Vault', sub));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<bool> hideAsset(AssetEntity asset, String album, {bool trash = false}) async {
    try {
      final src = await asset.originFile;
      if (src == null) return false;

      // 👈 1. Cache ఫైల్ నుండి కాకుండా, Original Asset నుండే రియల్ డీటెయిల్స్ లాగుతున్నాం! 🔥
      final realTitle = asset.title ?? p.basename(src.path);
      final realModified = asset.modifiedDateTime; 
      final realCreated = asset.createDateTime;    

      final media = await _dir('media');
      final thumbs = await _dir('thumbs');
      final id = '${DateTime.now().microsecondsSinceEpoch}_${_rand.nextInt(9999)}';
      
      // ఒరిజినల్ ఫైల్ ఎక్స్‌టెన్షన్ (.jpg/.png) ని తీసుకుంటున్నాం
      final ext = realTitle.contains('.') ? '.${realTitle.split('.').last}' : p.extension(src.path);
      final dest = p.join(media.path, '$id$ext');
      final destFile = File(dest);

      await src.copy(dest); 
      if (await destFile.length() != await src.length()) {
        await destFile.delete();
        return false;
      }

      // 👈 2. వాల్ట్ లోకి వచ్చిన ఫైల్ కి కచ్చితంగా పాత Original Dates సెట్ చేస్తున్నాం!
      try {
        await destFile.setLastModified(realModified);
        await destFile.setLastAccessed(realCreated);
      } catch (_) {
        // OS permissions ఇవ్వకపోతే స్కిప్ అవుతుంది, కానీ DB లో పక్కాగా సేవ్ అవుతుంది
      }

      String? thumbPath;
      final bytes = await asset.thumbnailDataWithSize(const ThumbnailSize(400, 400), quality: 80);
      if (bytes != null) {
        thumbPath = p.join(thumbs.path, '$id.jpg');
        await File(thumbPath).writeAsBytes(bytes);
      }

      // 👈 3. Database లో పిచ్చి పేర్లు కాకుండా, 'realTitle' మరియు 'realCreated' సేవ్ చేస్తున్నాం!
      final item = VaultItem(
        originalName: realTitle, // పక్కాగా IMG_20261011_12345.jpg లాంటి ఒరిజినల్ నేమ్ సేవ్ అవుతుంది
        encryptedPath: dest,
        thumbnailPath: thumbPath,
        type: asset.type == AssetType.video ? 'video' : 'image',
        albumName: album,
        addedDate: realCreated.toIso8601String(), // ఒరిజినల్ గా ఫోటో తీసిన ఎక్సాక్ట్ డేట్ సేవ్ అవుతుంది
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

  Future<void> exportToGallery(List<VaultItem> items, {bool removeFromVault = true}) async {
    for (final i in items) {
      if (i.type == 'video') {
        await PhotoManager.editor.saveVideo(File(i.encryptedPath), title: i.originalName);
      } else if (i.type == 'audio') {
        try {
          final downloadDir = Directory('/storage/emulated/0/Download');
          if (!await downloadDir.exists()) await downloadDir.create(recursive: true);
          final dest = p.join(downloadDir.path, i.originalName.isNotEmpty ? i.originalName : 'audio_${DateTime.now().millisecondsSinceEpoch}.mp3');
          await File(i.encryptedPath).copy(dest);
        } catch (e) {
          debugPrint('Audio Export Error: $e');
        }
      } else {
        await PhotoManager.editor.saveImageWithPath(i.encryptedPath, title: i.originalName);
      }
    }
    if (removeFromVault) await deleteForever(items);
  }
}