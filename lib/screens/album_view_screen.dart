import 'dart:io';
import 'dart:ui' as ui;
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:exif/exif.dart';
import 'package:collection/collection.dart';
import 'package:share_plus/share_plus.dart';
import 'package:provider/provider.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';

import '../core/theme_provider.dart';
import '../core/vault_service.dart';
import '../db/database_helper.dart';
import '../db/vault_item_model.dart';
import 'audio_player_screen.dart';
import 'photo_preview_screen.dart'; // UniversalPreviewScreen, PreviewItem, PreviewActions

// ════════════════════════════════════════════════════════════════════
//  SHARED BUTTON
// ════════════════════════════════════════════════════════════════════
class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(
                    color: color, fontSize: 13, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  HELPERS & METADATA
// ════════════════════════════════════════════════════════════════════
Future<bool> _copyItem(dynamic db, VaultItem it, String album) async {
  final src = File(it.encryptedPath);
  if (!await src.exists()) return false;
  final dot = it.encryptedPath.lastIndexOf('.');
  final slash = it.encryptedPath.lastIndexOf(RegExp(r'[\\/]'));
  final hasExt = dot > slash;
  final base = hasExt ? it.encryptedPath.substring(0, dot) : it.encryptedPath;
  final ext = hasExt ? it.encryptedPath.substring(dot) : '';
  final newPath = '${base}_copy_${DateTime.now().microsecondsSinceEpoch}$ext';
  await src.copy(newPath);
  try {
    final rows =
        await db.query('vault_items', where: 'id = ?', whereArgs: [it.id]);
    if (rows.isEmpty) throw StateError('row missing');
    final row = Map<String, Object?>.from(rows.first as Map)
      ..remove('id')
      ..['albumName'] = album
      ..['encryptedPath'] = newPath;
    await db.insert('vault_items', row);
    return true;
  } catch (_) {
    try {
      await File(newPath).delete();
    } catch (_) {}
    return false;
  }
}

Future<T> _withProgress<T>(
    BuildContext context, Future<T> Function() job) async {
  showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()));
  try {
    return await job();
  } finally {
    if (context.mounted) Navigator.of(context).pop();
  }
}

Future<String?> _pickAlbum(BuildContext context, String title, AppPalette p,
    {String? exclude}) async {
  final albums = (await DatabaseHelper.instance.fetchAlbums())
      .map((e) => e['albumName'] as String)
      .where((a) => a != exclude)
      .toList();
  if (!context.mounted) return null;
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      title: Text(title,
          style: TextStyle(color: p.text, fontWeight: FontWeight.bold)),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: ctrl,
              style: TextStyle(color: p.text),
              decoration: InputDecoration(
                  hintText: 'New album name',
                  hintStyle: TextStyle(color: p.sub))),
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(
              child: Wrap(spacing: 6, runSpacing: 6, children: [
                for (final a in albums)
                  ActionChip(
                      backgroundColor: p.bg2,
                      side: BorderSide(color: p.border),
                      label: Text(a, style: TextStyle(color: p.text)),
                      onPressed: () => Navigator.pop(ctx, a)),
              ]),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(
            onPressed: () {
              final n = ctrl.text.trim();
              if (n.isNotEmpty) Navigator.pop(ctx, n);
            },
            child: Text('Confirm',
                style: TextStyle(
                    color: p.accent, fontWeight: FontWeight.bold))),
      ],
    ),
  );
}

DateTime? _dateOf(VaultItem item) {
  // Prefer the stored capture timestamp, then fall back to the stored date string.
  final takenMs = item.takenMs;
  if (takenMs != null && takenMs > 0) {
    return DateTime.fromMillisecondsSinceEpoch(takenMs);
  }
  return DateTime.tryParse(item.addedDate.toString());
}

DateTime _effectiveSortDate(VaultItem item, int sortType) {
  if (sortType == 1) {
    final modifiedMs = item.modifiedMs;
    if (modifiedMs != null && modifiedMs > 0) {
      return DateTime.fromMillisecondsSinceEpoch(modifiedMs);
    }
    try {
      final file = File(item.encryptedPath);
      if (file.existsSync()) return file.statSync().modified;
    } catch (_) {}
  }
  return _dateOf(item) ?? DateTime.fromMillisecondsSinceEpoch(0);
}

String _exifValue(Map<String, IfdTag> tags, String key) {
  final value = tags[key]?.printable.trim();
  if (value == null || value.isEmpty || value == '0' || value == 'Unknown') {
    return '';
  }
  return value;
}

DateTime? _parseExifDate(String value) {
  // EXIF normally stores dates as yyyy:MM:dd HH:mm:ss.
  final match = RegExp(r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})')
      .firstMatch(value.trim());
  if (match != null) {
    return DateTime.tryParse(
        '${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${match[6]}');
  }
  return DateTime.tryParse(value);
}

String _fmtSize(int b) {
  if (b <= 0) return '-';
  const u = ['B', 'KB', 'MB', 'GB'];
  var v = b.toDouble(), i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${u[i]}';
}

Future<Map<String, String>> _loadMeta(VaultItem item) async {
  final f = File(item.encryptedPath);
  final out = <String, String>{};
  final storedName = item.originalName?.toString() ?? '';
  final name = storedName.isNotEmpty
      ? storedName
      : item.encryptedPath.split(RegExp(r'[\\/]')).last;
  out['Name'] = name;
  out['Album'] = item.albumName;

  DateTime? captureDate;
  Map<String, IfdTag> exifTags = {};

  if (await f.exists()) {
    try {
      final bytes = await f.readAsBytes();
      if (item.type != 'audio') {
        try {
          exifTags = await readExifFromBytes(bytes);
        } catch (_) {
          exifTags = {};
        }
      }

      // EXIF capture time has priority over the database fallback.
      for (final key in [
        'EXIF DateTimeOriginal',
        'EXIF DateTimeDigitized',
        'Image DateTime'
      ]) {
        final raw = _exifValue(exifTags, key);
        if (raw.isNotEmpty) {
          captureDate = _parseExifDate(raw);
          if (captureDate != null) break;
        }
      }

      final stat = await f.stat();
      out['Size'] = _fmtSize(stat.size);
      out['File Modified'] =
          DateFormat('EEE, d MMM yyyy • h:mm a').format(stat.modified);
      final ext = name.contains('.') ? name.split('.').last.toUpperCase() : '-';
      out['Type'] = ext;

      if (item.type != 'audio') {
        try {
          final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
          final d = await ui.ImageDescriptor.encoded(buf);
          out['Resolution'] =
              '${d.width} × ${d.height} (${((d.width * d.height) / 1e6).toStringAsFixed(1)} MP)';
          d.dispose();
          buf.dispose();
        } catch (_) {}
      }
    } catch (_) {
      out['Size'] = 'Unable to read file';
    }
  } else {
    out['Size'] = 'File missing';
  }

  captureDate ??= _dateOf(item);
  out['Date Taken'] = captureDate == null
      ? 'Not available'
      : DateFormat('EEE, d MMM yyyy • h:mm:ss a').format(captureDate);

  // Show useful camera EXIF fields when present. Missing fields are omitted.
  final exifFields = <String, String>{
    'Camera Make': _exifValue(exifTags, 'Image Make'),
    'Camera Model': _exifValue(exifTags, 'Image Model'),
    'Lens Model': _exifValue(exifTags, 'EXIF LensModel'),
    'Exposure Time': _exifValue(exifTags, 'EXIF ExposureTime'),
    'Aperture': _exifValue(exifTags, 'EXIF FNumber'),
    'ISO': _exifValue(exifTags, 'EXIF ISOSpeedRatings'),
    'Focal Length': _exifValue(exifTags, 'EXIF FocalLength'),
    'Flash': _exifValue(exifTags, 'EXIF Flash'),
    'Orientation': _exifValue(exifTags, 'Image Orientation'),
    'Software': _exifValue(exifTags, 'Image Software'),
  };
  for (final entry in exifFields.entries) {
    if (entry.value.isNotEmpty) out[entry.key] = entry.value;
  }

  out['Path'] = item.encryptedPath;
  return out;
}

/// Universal viewer ki ichhe meta.
/// Viewer tana Path row (tappable) add chesthundi, kabatti ikkada Path teesesanu.
/// EXIF key names viewer tho match chesanu, anduke duplicate rows raavu.
Future<Map<String, String>> _previewMeta(VaultItem item) async {
  final m = await _loadMeta(item);
  const rename = {
    'Date Taken': 'Taken',
    'Exposure Time': 'Shutter',
    'Focal Length': 'Focal length',
  };

  final cam = [m['Camera Make'], m['Camera Model']]
      .whereType<String>()
      .where((e) => e.isNotEmpty)
      .join(' ');

  final out = <String, String>{};
  m.forEach((k, v) {
    if (k == 'Path' || k == 'Camera Make' || k == 'Camera Model') return;
    out[rename[k] ?? k] = v;
  });
  if (cam.isNotEmpty) out['Camera'] = cam;
  return out;
}

// ════════════════════════════════════════════════════════════════════
//  ALBUM VIEW SCREEN (Vault Items Grid)
// ════════════════════════════════════════════════════════════════════
class AlbumViewScreen extends StatefulWidget {
  final String albumName;
  const AlbumViewScreen({super.key, required this.albumName});
  @override
  State<AlbumViewScreen> createState() => _AlbumViewScreenState();
}

class _AlbumViewScreenState extends State<AlbumViewScreen> {
  List<VaultItem> _items = [];
  Map<String, List<VaultItem>> _groupedItems = {};
  final Set<int> _selected = {};
  bool _loading = true;
  int _sortType = 0; // 0: Created Date, 1: Modified Date, 2: Size
  String? _filterType; // null = all, 'video' | 'image' | 'audio'

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    final allItems = await DatabaseHelper.instance.fetchAll();

    var albumItems = allItems
        .where((i) =>
            i.albumName == widget.albumName &&
            i.isDeleted == 0 &&
            i.type != 'folder')
        .toList();

    if (_filterType != null) {
      albumItems = albumItems.where((i) => i.type == _filterType).toList();
    }

    // Created Date uses capture timestamp (takenMs / EXIF-derived date fallback).
    // Modified Date uses saved modifiedMs, falling back to the file's modified time.
    albumItems.sort((a, b) {
      if (_sortType == 0 || _sortType == 1) {
        return _effectiveSortDate(b, _sortType)
            .compareTo(_effectiveSortDate(a, _sortType));
      }
      final fA = File(a.encryptedPath);
      final fB = File(b.encryptedPath);
      final sA = fA.existsSync() ? fA.statSync().size : 0;
      final sB = fB.existsSync() ? fB.statSync().size : 0;
      return sB.compareTo(sA);
    });

    if (mounted) {
      setState(() {
        _items = albumItems;
        _groupItems();
        _loading = false;
      });
    }
  }

  void _groupItems() {
    _groupedItems = groupBy(_items, (VaultItem item) {
      final date = _effectiveSortDate(item, _sortType);

      if (_sortType == 2) {
        final f = File(item.encryptedPath);
        final size = f.existsSync() ? f.statSync().size : 0;
        if (size > 1024 * 1024 * 50) return "Larger than 50MB";
        if (size > 1024 * 1024 * 10) return "10MB - 50MB";
        return "Under 10MB";
      }

      final now = DateTime.now(),
          today = DateTime(now.year, now.month, now.day),
          yesterday = today.subtract(const Duration(days: 1));
      final itemDate = DateTime(date.year, date.month, date.day);

      if (itemDate == today) return "Today";
      if (itemDate == yesterday) return "Yesterday";
      if (date.year == now.year) return DateFormat('MMMM d').format(date);
      return DateFormat('MMMM yyyy').format(date);
    });
  }

  void _toggle(VaultItem a) => setState(() {
        _selected.contains(a.id) ? _selected.remove(a.id) : _selected.add(a.id!);
      });

  void _showProgressDialog(
      String title, int total, ValueNotifier<int> progress) {
    final p = context.read<ThemeProvider>().p;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: Dialog(
          backgroundColor: p.surface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 24),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: p.accent),
                const SizedBox(width: 24),
                ValueListenableBuilder<int>(
                  valueListenable: progress,
                  builder: (_, val, __) => Text(
                    '$title\n$val / $total',
                    style: TextStyle(
                        color: p.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Import Audio (file_selector) ──
  Future<void> _importAudio(AppPalette p) async {
    try {
      const XTypeGroup audioTypeGroup = XTypeGroup(
        label: 'Audio Files',
        extensions: ['mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac'],
      );

      final List<XFile> files =
          await openFiles(acceptedTypeGroups: [audioTypeGroup]);
      if (files.isEmpty) return;

      final progress = ValueNotifier<int>(0);
      _showProgressDialog('Importing Audio...', files.length, progress);

      final db = await DatabaseHelper.instance.database;
      final dir = await getApplicationDocumentsDirectory();
      final vaultDir = Directory('${dir.path}/vault_audio');
      if (!await vaultDir.exists()) await vaultDir.create(recursive: true);

      int successCount = 0;
      for (int i = 0; i < files.length; i++) {
        progress.value = i + 1;
        final filePath = files[i].path;
        final file = File(filePath);
        final originalName = files[i].name;
        final ext =
            originalName.contains('.') ? originalName.split('.').last : 'mp3';
        final newName =
            'audio_${DateTime.now().microsecondsSinceEpoch}_$i.$ext';
        final newPath = '${vaultDir.path}/$newName';

        await file.copy(newPath);

        await db.insert('vault_items', {
          'originalName': originalName,
          'encryptedPath': newPath,
          'thumbnailPath': null,
          'type': 'audio',
          'albumName': widget.albumName,
          'addedDate': DateTime.now().toIso8601String(),
          'isDeleted': 0,
        });

        try {
          await file.delete();
        } catch (_) {}
        successCount++;
      }

      if (mounted) {
        Navigator.pop(context); // Close dialog
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$successCount Audio files imported 🎵')));
        _loadItems();
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e ❌')));
      }
    }
  }

  // ── BOTTOM BAR ACTIONS ──
  Future<void> _shareSelected() async {
    final chosen = _items.where((i) => _selected.contains(i.id)).toList();
    final files = [
      for (final i in chosen)
        if (File(i.encryptedPath).existsSync()) XFile(i.encryptedPath)
    ];
    if (files.isNotEmpty) {
      await Share.shareXFiles(files);
      setState(() => _selected.clear());
    }
  }

  Future<void> _copySelected(AppPalette p) async {
    final target = await _pickAlbum(context, 'Copy to', p);
    if (target == null || !mounted) return;
    final chosen = _items.where((i) => _selected.contains(i.id)).toList();

    final progress = ValueNotifier<int>(0);
    _showProgressDialog('Copying...', chosen.length, progress);

    final db = await DatabaseHelper.instance.database;
    int successCount = 0;
    for (int i = 0; i < chosen.length; i++) {
      progress.value = i + 1;
      if (await _copyItem(db, chosen[i], target)) successCount++;
    }

    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$successCount/${chosen.length} copied to $target 📄')));
    setState(() => _selected.clear());
    _loadItems();
  }

  Future<void> _moveSelected(AppPalette p) async {
    final target =
        await _pickAlbum(context, 'Move to', p, exclude: widget.albumName);
    if (target == null || !mounted) return;
    final chosen = _items.where((i) => _selected.contains(i.id)).toList();

    final progress = ValueNotifier<int>(0);
    _showProgressDialog('Moving...', chosen.length, progress);

    final db = await DatabaseHelper.instance.database;
    int successCount = 0;
    for (int i = 0; i < chosen.length; i++) {
      progress.value = i + 1;
      await db.update('vault_items', {'albumName': target},
          where: 'id = ?', whereArgs: [chosen[i].id]);
      successCount++;
    }

    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$successCount/${chosen.length} moved to $target 🚀')));
    setState(() => _selected.clear());
    _loadItems();
  }

  Future<void> _trashSelected() async {
    await _withProgress(context,
        () => DatabaseHelper.instance.setDeleted(_selected.toList(), true));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${_selected.length} items moved to bin 🗑️')));
      setState(() => _selected.clear());
      _loadItems();
    }
  }

  Future<String?> _showAlbumStats(BuildContext context, AppPalette p) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: p.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => FutureBuilder<Map<String, String>>(
        future: () async {
          final allItems = await DatabaseHelper.instance.fetchAll();
          final baseItems = allItems
              .where((i) =>
                  i.albumName == widget.albumName &&
                  i.isDeleted == 0 &&
                  i.type != 'folder')
              .toList();

          int pCount = 0,
              vCount = 0,
              aCount = 0,
              pSize = 0,
              vSize = 0,
              aSize = 0;
          for (final item in baseItems) {
            final f = File(item.encryptedPath);
            int size = 0;
            if (await f.exists()) size = (await f.stat()).size;

            if (item.type == 'video') {
              vCount++;
              vSize += size;
            } else if (item.type == 'audio') {
              aCount++;
              aSize += size;
            } else {
              pCount++;
              pSize += size;
            }
          }
          return {
            'Photos': '$pCount items  •  ${_fmtSize(pSize)}',
            'Videos': '$vCount items  •  ${_fmtSize(vSize)}',
            'Audios': '$aCount items  •  ${_fmtSize(aSize)}',
            'Total Size': _fmtSize(pSize + vSize + aSize),
          };
        }(),
        builder: (ctx, snap) {
          final m = snap.data;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
              child: m == null
                  ? SizedBox(
                      height: 160,
                      child: Center(
                          child: CircularProgressIndicator(color: p.accent)))
                  : Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('${widget.albumName} Info',
                          style: TextStyle(
                              color: p.text,
                              fontSize: 20,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(height: 20),
                      for (final e in m.entries)
                        GestureDetector(
                          onTap: () {
                            if (e.key == 'Videos') {
                              Navigator.pop(ctx, 'video');
                            } else if (e.key == 'Photos') {
                              Navigator.pop(ctx, 'image');
                            } else if (e.key == 'Audios') {
                              Navigator.pop(ctx, 'audio');
                            } else {
                              Navigator.pop(ctx, 'all');
                            }
                          },
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Row(children: [
                              Icon(
                                  e.key == 'Photos'
                                      ? Icons.image_outlined
                                      : e.key == 'Videos'
                                          ? Icons.play_circle_outline
                                          : e.key == 'Audios'
                                              ? Icons.audiotrack_rounded
                                              : Icons.storage_rounded,
                                  color: p.accent,
                                  size: 24),
                              const SizedBox(width: 12),
                              SizedBox(
                                  width: 100,
                                  child: Text(e.key,
                                      style: TextStyle(
                                          color: p.sub,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600))),
                              Expanded(
                                  child: Text(e.value,
                                      style: TextStyle(
                                          color: p.text,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700),
                                      textAlign: TextAlign.right)),
                            ]),
                          ),
                        ),
                    ]),
            ),
          );
        },
      ),
    );
  }

  // ── UNIVERSAL VIEWER ──
  Future<void> _openPreview(VaultItem item) async {
    final p = context.read<ThemeProvider>().p;
    // audios ni swipe list nundi exclude chestunnam
    final media = _items.where((e) => e.type != 'audio').toList();
    final idx = media.indexWhere((e) => e.id == item.id);
    if (idx == -1) return;

    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => UniversalPreviewScreen(
          items: media
              .map((v) => PreviewItem.fromVault(
                    v,
                    detailsLoader: () => _previewMeta(v),
                  ))
              .toList(),
          initialIndex: idx,
          headerLabel: widget.albumName,
          actions: [
            ...PreviewActions.vault(), // Export, Bin, Crop/Rotate, Share
            _copyAction(p),
            _moveAction(p),
          ],
        ),
      ),
    );
    if (changed == true) _loadItems();
  }

  PreviewAction _copyAction(AppPalette p) => PreviewAction(
        icon: Icons.copy_rounded,
        label: 'Copy to',
        color: const Color(0xFF7CE0B0),
        inDock: false,
        removesItem: false,
        run: (i) async {
          final v = i.data as VaultItem;
          final target = await _pickAlbum(context, 'Copy to', p);
          if (target == null || !mounted) throw const PreviewCancelled();

          final db = await DatabaseHelper.instance.database;
          final ok =
              await _withProgress(context, () => _copyItem(db, v, target));
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(ok ? 'Copied to $target ✅' : 'Copy failed ❌')),
          );
        },
      );

  PreviewAction _moveAction(AppPalette p) => PreviewAction(
        icon: Icons.drive_file_move_rounded,
        label: 'Move to',
        color: const Color(0xFFB892FF),
        inDock: false,
        // removesItem default true: move tarvata item ee album lo undadu
        run: (i) async {
          final v = i.data as VaultItem;
          final target = await _pickAlbum(context, 'Move to', p,
              exclude: widget.albumName);
          if (target == null || !mounted) throw const PreviewCancelled();

          final db = await DatabaseHelper.instance.database;
          await _withProgress(
            context,
            () => db.update('vault_items', {'albumName': target},
                where: 'id = ?', whereArgs: [v.id]),
          );
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Moved to $target 🚀')),
          );
        },
      );

  Future<void> _restoreToGallery() async {
    final chosen = _items.where((i) => _selected.contains(i.id)).toList();
    if (chosen.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final p = context.read<ThemeProvider>().p;
        return AlertDialog(
          backgroundColor: p.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
          title: Text('Unhide Photos?',
              style: TextStyle(color: p.text, fontWeight: FontWeight.bold)),
          content: Text(
              'These ${chosen.length} items will be moved back to public gallery. Confirm?',
              style: TextStyle(color: p.sub)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text('Cancel', style: TextStyle(color: p.text))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('Unhide',
                    style: TextStyle(
                        color: p.accent, fontWeight: FontWeight.bold))),
          ],
        );
      },
    );

    if (confirm != true || !mounted) return;

    await _withProgress(context, () => VaultService().exportToGallery(chosen));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${chosen.length} items restored to gallery 🔓')));
      setState(() => _selected.clear());
      _loadItems();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final p = context.watch<ThemeProvider>().p;
    final selecting = _selected.isNotEmpty;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light),
      child: Scaffold(
        backgroundColor: p.bg,
        body: Stack(
          children: [
            Positioned(
              top: -90,
              right: -80,
              child: IgnorePointer(
                child: Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [
                      p.accent.withOpacity(0.12),
                      p.accent.withOpacity(0.0)
                    ]),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: _loading
                  ? Center(child: CircularProgressIndicator(color: p.accent))
                  : _items.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                      width: 92,
                                      height: 92,
                                      decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: p.glass,
                                          border: Border.all(color: p.border)),
                                      child: Icon(Icons.photo_library_outlined,
                                          size: 42, color: p.accent)),
                                  const SizedBox(height: 18),
                                  Text('Nothing here yet',
                                      style: TextStyle(
                                          color: p.text,
                                          fontSize: 19,
                                          fontWeight: FontWeight.w800)),
                                  const SizedBox(height: 7),
                                  Text(
                                      'Photos and videos in this album will appear here.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: p.sub,
                                          fontSize: 13,
                                          height: 1.45)),
                                ]),
                          ),
                        )
                      : CustomScrollView(
                          physics: const BouncingScrollPhysics(),
                          slivers: [
                            SliverPadding(
                                padding:
                                    EdgeInsets.only(top: mq.padding.top + 60)),
                            ..._groupedItems.entries.expand((entry) {
                              final dateHeader = entry.key;
                              final itemsInGroup = entry.value;
                              final width = mq.size.width;
                              final columns = width >= 1100
                                  ? 6
                                  : width >= 850
                                      ? 5
                                      : width >= 600
                                          ? 4
                                          : 3;

                              return [
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding:
                                        const EdgeInsets.fromLTRB(16, 18, 16, 10),
                                    child: Row(children: [
                                      Container(
                                          width: 4,
                                          height: 18,
                                          decoration: BoxDecoration(
                                              color: p.accent,
                                              borderRadius:
                                                  BorderRadius.circular(8))),
                                      const SizedBox(width: 10),
                                      Text(dateHeader,
                                          style: TextStyle(
                                              color: p.text,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w800,
                                              letterSpacing: 0.2)),
                                      const SizedBox(width: 8),
                                      Expanded(
                                          child: Container(
                                              height: 1,
                                              color:
                                                  p.border.withOpacity(0.7))),
                                      const SizedBox(width: 8),
                                      Text('${itemsInGroup.length}',
                                          style: TextStyle(
                                              color: p.sub,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700)),
                                    ]),
                                  ),
                                ),
                                SliverPadding(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 8),
                                  sliver: SliverGrid(
                                    gridDelegate:
                                        SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: columns,
                                      crossAxisSpacing: 6,
                                      mainAxisSpacing: 6,
                                    ),
                                    delegate: SliverChildBuilderDelegate(
                                      (context, index) {
                                        final item = itemsInGroup[index];
                                        final sel = _selected.contains(item.id);
                                        final isVideo = item.type == 'video';
                                        final isAudio = item.type == 'audio';

                                        // Image aina video aina thumbnail ne vaadali (RAM save)
                                        final imgPath =
                                            (item.thumbnailPath != null)
                                                ? item.thumbnailPath!
                                                : item.encryptedPath;
                                        final file = File(imgPath);

                                        final framed = DecoratedBox(
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.topLeft,
                                              end: Alignment.bottomRight,
                                              colors: [
                                                p.glass,
                                                p.surface.withOpacity(0.92)
                                              ],
                                            ),
                                            borderRadius:
                                                BorderRadius.circular(16),
                                            border: Border.all(
                                              color: sel
                                                  ? p.accent.withOpacity(0.95)
                                                  : p.border.withOpacity(0.9),
                                              width: sel ? 2 : 1,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                  color: Colors.black
                                                      .withOpacity(0.10),
                                                  blurRadius: 10,
                                                  offset: const Offset(0, 4)),
                                            ],
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.all(2),
                                            child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(13),
                                              child: Stack(
                                                  fit: StackFit.expand,
                                                  children: [
                                                    isAudio
                                                        ? Container(
                                                            color: p.surface,
                                                            child: Column(
                                                              mainAxisAlignment:
                                                                  MainAxisAlignment
                                                                      .center,
                                                              children: [
                                                                Icon(
                                                                    Icons
                                                                        .music_note_rounded,
                                                                    color:
                                                                        p.accent,
                                                                    size: 40),
                                                                const SizedBox(
                                                                    height: 8),
                                                                Padding(
                                                                  padding: const EdgeInsets
                                                                      .symmetric(
                                                                      horizontal:
                                                                          8),
                                                                  child: Text(
                                                                    item.originalName ??
                                                                        'Audio File',
                                                                    maxLines: 2,
                                                                    overflow:
                                                                        TextOverflow
                                                                            .ellipsis,
                                                                    textAlign:
                                                                        TextAlign
                                                                            .center,
                                                                    style: TextStyle(
                                                                        color: p
                                                                            .text,
                                                                        fontSize:
                                                                            11,
                                                                        fontWeight:
                                                                            FontWeight
                                                                                .bold),
                                                                  ),
                                                                )
                                                              ],
                                                            ),
                                                          )
                                                        : Hero(
                                                            tag:
                                                                'vault_${item.id}',
                                                            child: file
                                                                    .existsSync()
                                                                ? Image.file(
                                                                    file,
                                                                    fit: BoxFit
                                                                        .cover,
                                                                    gaplessPlayback:
                                                                        true,
                                                                    cacheWidth:
                                                                        300)
                                                                : Container(
                                                                    color:
                                                                        p.bg2,
                                                                    child: Icon(
                                                                        Icons
                                                                            .broken_image,
                                                                        color: p
                                                                            .sub)),
                                                          ),
                                                    if (isVideo)
                                                      Positioned(
                                                        right: 6,
                                                        bottom: 6,
                                                        child: Container(
                                                          padding:
                                                              const EdgeInsets
                                                                  .symmetric(
                                                                  horizontal: 6,
                                                                  vertical: 3),
                                                          decoration: BoxDecoration(
                                                              color: Colors
                                                                  .black
                                                                  .withOpacity(
                                                                      0.75),
                                                              borderRadius:
                                                                  BorderRadius
                                                                      .circular(
                                                                          6)),
                                                          child: const Row(
                                                              mainAxisSize:
                                                                  MainAxisSize
                                                                      .min,
                                                              children: [
                                                                Icon(
                                                                    Icons
                                                                        .play_arrow_rounded,
                                                                    color: Colors
                                                                        .white,
                                                                    size: 14),
                                                                SizedBox(
                                                                    width: 4),
                                                                Text('VIDEO',
                                                                    style: TextStyle(
                                                                        color: Colors
                                                                            .white,
                                                                        fontSize:
                                                                            10,
                                                                        fontWeight:
                                                                            FontWeight
                                                                                .bold,
                                                                        letterSpacing:
                                                                            0.5)),
                                                              ]),
                                                        ),
                                                      ),
                                                    AnimatedContainer(
                                                        duration:
                                                            const Duration(
                                                                milliseconds:
                                                                    180),
                                                        color: sel
                                                            ? p.accent
                                                                .withOpacity(
                                                                    0.22)
                                                            : Colors
                                                                .transparent),
                                                    if (sel)
                                                      Positioned(
                                                        top: 7,
                                                        left: 7,
                                                        child: AnimatedContainer(
                                                          duration:
                                                              const Duration(
                                                                  milliseconds:
                                                                      180),
                                                          width: 24,
                                                          height: 24,
                                                          decoration:
                                                              BoxDecoration(
                                                                  shape: BoxShape
                                                                      .circle,
                                                                  color: p
                                                                      .accent),
                                                          child: const Icon(
                                                              Icons
                                                                  .check_rounded,
                                                              size: 16,
                                                              color:
                                                                  Colors.white),
                                                        ),
                                                      ),
                                                  ]),
                                            ),
                                          ),
                                        );

                                        return GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () async {
                                            if (selecting) {
                                              _toggle(item);
                                            } else if (isAudio) {
                                              await Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                      builder: (_) =>
                                                          AudioPlayerScreen(
                                                              file: File(item
                                                                  .encryptedPath),
                                                              title: item
                                                                      .originalName ??
                                                                  'Audio')));
                                            } else {
                                              await _openPreview(item);
                                            }
                                          },
                                          onLongPress: () {
                                            HapticFeedback.mediumImpact();
                                            _toggle(item);
                                          },
                                          child: AnimatedScale(
                                            scale: sel ? 0.86 : 1,
                                            duration: const Duration(
                                                milliseconds: 200),
                                            curve: Curves.easeOutCubic,
                                            child: framed,
                                          ),
                                        );
                                      },
                                      childCount: itemsInGroup.length,
                                    ),
                                  ),
                                ),
                              ];
                            }),
                            const SliverPadding(
                                padding: EdgeInsets.only(bottom: 120)),
                          ],
                        ),
            ),

            // Top Glass Bar
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: ClipRRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                        color: p.bar,
                        border: Border(bottom: BorderSide(color: p.border))),
                    child: Padding(
                      padding: EdgeInsets.only(top: mq.padding.top),
                      child: SizedBox(
                        height: 56,
                        child: selecting
                            ? Row(
                                children: [
                                  IconButton(
                                      icon: Icon(Icons.close_rounded,
                                          color: p.text),
                                      onPressed: () =>
                                          setState(() => _selected.clear())),
                                  Expanded(
                                      child: Text('${_selected.length} Selected',
                                          style: TextStyle(
                                              color: p.text,
                                              fontSize: 18,
                                              fontWeight: FontWeight.bold))),
                                  IconButton(
                                      icon: Icon(Icons.select_all_rounded,
                                          color: p.text),
                                      onPressed: () => setState(() =>
                                          _selected.length == _items.length
                                              ? _selected.clear()
                                              : _selected.addAll(
                                                  _items.map((e) => e.id!)))),
                                  const SizedBox(width: 8),
                                ],
                              )
                            : Row(
                                children: [
                                  const SizedBox(width: 8),
                                  IconButton(
                                      icon: Icon(
                                          Icons.arrow_back_ios_new_rounded,
                                          color: p.text,
                                          size: 20),
                                      onPressed: () => Navigator.pop(context)),
                                  Expanded(
                                    child: Text(widget.albumName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            color: p.text,
                                            fontSize: 19,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: -0.25)),
                                  ),

                                  // Import Audio Button
                                  IconButton(
                                    tooltip: 'Import Audio',
                                    icon: Icon(Icons.audio_file_rounded,
                                        color: p.accent),
                                    onPressed: () => _importAudio(p),
                                  ),

                                  PopupMenuButton<int>(
                                    icon: Icon(Icons.sort_rounded,
                                        color: p.text),
                                    color: p.surface,
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(16)),
                                    initialValue: _sortType,
                                    onSelected: (val) {
                                      if (val != _sortType) {
                                        setState(() => _sortType = val);
                                        _loadItems();
                                      }
                                    },
                                    itemBuilder: (_) => [
                                      PopupMenuItem(
                                          value: 0,
                                          child: Text('Created Date',
                                              style: TextStyle(color: p.text))),
                                      PopupMenuItem(
                                          value: 1,
                                          child: Text('Modified Date',
                                              style: TextStyle(color: p.text))),
                                      PopupMenuItem(
                                          value: 2,
                                          child: Text('Size',
                                              style: TextStyle(color: p.text))),
                                    ],
                                  ),

                                  IconButton(
                                      tooltip: 'Album Info',
                                      icon: Icon(
                                          _filterType != null
                                              ? Icons.filter_alt_rounded
                                              : Icons.info_outline_rounded,
                                          color: _filterType != null
                                              ? p.accent
                                              : p.text),
                                      onPressed: () async {
                                        final res =
                                            await _showAlbumStats(context, p);
                                        if (res != null) {
                                          setState(() => _filterType =
                                              res == 'all' ? null : res);
                                          _loadItems();
                                        }
                                      }),
                                  const SizedBox(width: 8),
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Bottom Glass Actions Bar
            Positioned(
              left: 12,
              right: 12,
              bottom: mq.padding.bottom + 12,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                transitionBuilder: (c, a) => FadeTransition(
                    opacity: a,
                    child: SlideTransition(
                        position: Tween(
                                begin: const Offset(0, 0.6), end: Offset.zero)
                            .animate(a),
                        child: c)),
                child: selecting
                    ? ClipRRect(
                        key: const ValueKey('vault_actions_bar'),
                        borderRadius: BorderRadius.circular(28),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                          child: DecoratedBox(
                            decoration: BoxDecoration(color: p.bar),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 12, horizontal: 8),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: [
                                  _ActionBtn(
                                      icon: Icons.ios_share_rounded,
                                      label: 'Share',
                                      color: p.accent,
                                      onTap: _shareSelected),
                                  _ActionBtn(
                                      icon: Icons.output_rounded,
                                      label: 'Unhide',
                                      color: p.accent,
                                      onTap: _restoreToGallery),
                                  _ActionBtn(
                                      icon: Icons.copy_rounded,
                                      label: 'Copy',
                                      color: p.accent,
                                      onTap: () => _copySelected(p)),
                                  _ActionBtn(
                                      icon: Icons.drive_file_move_rounded,
                                      label: 'Move',
                                      color: p.accent,
                                      onTap: () => _moveSelected(p)),
                                  _ActionBtn(
                                      icon: Icons.delete_outline_rounded,
                                      label: 'Bin',
                                      color: Colors.redAccent,
                                      onTap: _trashSelected),
                                ],
                              ),
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}