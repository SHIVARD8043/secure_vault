import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

/// EXIF DateTimeOriginal based taken-date cache (persistent).
class TakenStore {
  TakenStore._();
  static final instance = TakenStore._();
  static const _ch = MethodChannel('vault/export');

  // key: "<assetId>_<modifiedSecs>" -> ms (0 = date dorakaledu)
  final Map<String, int> _m = {};
  bool _loaded = false, _dirty = false;

  String _k(AssetEntity a) =>
      '${a.id}_${a.modifiedDateTime.millisecondsSinceEpoch ~/ 1000}';

  Future<File> _file() async {
    final d = await getApplicationSupportDirectory();
    return File(p.join(d.path, 'taken_cache.json'));
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (await f.exists()) {
        final raw = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        raw.forEach((k, v) => _m[k] = (v as num).toInt());
      }
    } catch (e) {
      debugPrint('TakenStore load failed: $e');
    }
  }

  Future<void> _save() async {
    if (!_dirty) return;
    _dirty = false;
    try {
      await (await _file()).writeAsString(jsonEncode(_m));
    } catch (e) {
      debugPrint('TakenStore save failed: $e');
    }
  }

  /// Taken date: EXIF/DATE_TAKEN (cache) -> fallback createDateTime
  DateTime dateOf(AssetEntity a) {
    final t = _m[_k(a)];
    if (t != null && t > 0) return DateTime.fromMillisecondsSinceEpoch(t);
    return a.createDateTime;
  }

  Future<void> fill(List<AssetEntity> list) async {
    if (!Platform.isAndroid) return;
    await load();
    final missing = list
        .where((a) => a.type == AssetType.image && !_m.containsKey(_k(a)))
        .toList();
    if (missing.isEmpty) return;

    for (var i = 0; i < missing.length; i += 300) {
      final chunk = missing.sublist(i, math_min(i + 300, missing.length));
      try {
        final res = await _ch.invokeMethod<Map>(
            'takenDates', {'ids': chunk.map((a) => a.id).toList()});
        for (final a in chunk) {
          final v = res?[a.id];
          _m[_k(a)] = v is num ? v.toInt() : 0;
          _dirty = true;
        }
      } catch (e) {
        debugPrint('takenDates failed: $e');
      }
    }
    await _save();
  }
}

int math_min(int a, int b) => a < b ? a : b;