import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';

// ════════════════════════════════════════════════════════════════════
//  Colors passed in from the gallery palette (keeps _P private)
// ════════════════════════════════════════════════════════════════════
class ActionColors {
  const ActionColors({
    required this.surface,
    required this.text,
    required this.sub,
    required this.accent,
    required this.border,
  });
  final Color surface, text, sub, accent, border;
}

enum GalleryAction { share, copy, move, bin }

class AlbumTarget {
  const AlbumTarget({this.existing, this.newName});
  final AssetPathEntity? existing;
  final String? newName;
  String get name => existing?.name ?? newName ?? 'My_Photos';
}

// ════════════════════════════════════════════════════════════════════
//  ENTRY POINT  – shows the dialog, runs the action.
//  Returns true if the library changed (move / bin) so caller reloads.
// ════════════════════════════════════════════════════════════════════
Future<bool> runGalleryAction(
  BuildContext context,
  ActionColors c,
  List<AssetEntity> items,
) async {
  if (items.isEmpty) return false;
  final action = await _showActionDialog(context, c, items.length);
  if (action == null || !context.mounted) return false;

  switch (action) {
    case GalleryAction.share:
      await _share(context, items);
      return false;

    case GalleryAction.copy:
      final t = await _pickAlbum(context, c, 'Copy to');
      if (t == null || !context.mounted) return false;
      final ok = await _withProgress(context, () => _copy(items, t));
      if (context.mounted) _toast(context, '$ok/${items.length} copied to ${t.name}');
      return false;

    case GalleryAction.move:
      final t = await _pickAlbum(context, c, 'Move to');
      if (t == null || !context.mounted) return false;
      final ok = await _withProgress(context, () => _move(items, t));
      if (context.mounted) _toast(context, '$ok/${items.length} moved to ${t.name}');
      return ok > 0;

    case GalleryAction.bin:
      final sure = await _confirmBin(context, c, items.length);
      if (sure != true || !context.mounted) return false;
      final ok = await _withProgress(context, () => _bin(items));
      if (context.mounted) _toast(context, '$ok moved to bin');
      return ok > 0;
  }
}

// ─────────────────────────── DIALOGS ───────────────────────────
Future<GalleryAction?> _showActionDialog(BuildContext context, ActionColors c, int n) {
  Widget tile(IconData i, String t, GalleryAction a, {Color? color}) => ListTile(
        leading: Icon(i, color: color ?? c.accent),
        title: Text(t, style: TextStyle(color: color ?? c.text, fontWeight: FontWeight.w600)),
        onTap: () => Navigator.pop(context, a),
      );

  return showDialog<GalleryAction>(
    context: context,
    builder: (_) => SimpleDialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      title: Text('$n selected',
          style: TextStyle(color: c.text, fontSize: 18, fontWeight: FontWeight.w700)),
      children: [
        tile(Icons.ios_share_rounded, 'Share to', GalleryAction.share),
        tile(Icons.copy_rounded, 'Copy to', GalleryAction.copy),
        tile(Icons.drive_file_move_rounded, 'Move to', GalleryAction.move),
        tile(Icons.delete_outline_rounded, 'Bin', GalleryAction.bin, color: Colors.redAccent),
      ],
    ),
  );
}

Future<bool?> _confirmBin(BuildContext context, ActionColors c, int n) => showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        title: Text('Move $n item(s) to bin?', style: TextStyle(color: c.text, fontSize: 17)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Bin', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );

Future<AlbumTarget?> _pickAlbum(BuildContext context, ActionColors c, String title) async {
  final albums = await PhotoManager.getAssetPathList(type: RequestType.image, hasAll: false);
  if (!context.mounted) return null;
  final ctrl = TextEditingController();
  return showDialog<AlbumTarget>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      title: Text(title, style: TextStyle(color: c.text, fontSize: 18, fontWeight: FontWeight.w700)),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: ctrl,
            style: TextStyle(color: c.text),
            decoration: InputDecoration(
                hintText: 'New album name', hintStyle: TextStyle(color: c.sub)),
          ),
          const SizedBox(height: 10),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final a in albums)
                ListTile(
                  dense: true,
                  leading: Icon(Icons.photo_album_outlined, color: c.accent),
                  title: Text(a.name, style: TextStyle(color: c.text)),
                  onTap: () => Navigator.pop(ctx, AlbumTarget(existing: a)),
                ),
            ]),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(
          onPressed: () {
            final n = ctrl.text.trim();
            if (n.isEmpty) return;
            Navigator.pop(ctx, AlbumTarget(newName: n));
          },
          child: const Text('Create'),
        ),
      ],
    ),
  );
}

// ─────────────────────────── WORKERS ───────────────────────────
Future<T> _withProgress<T>(BuildContext context, Future<T> Function() job) async {
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

void _toast(BuildContext context, String m) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

Future<void> _share(BuildContext context, List<AssetEntity> items) async {
  final files = <XFile>[];
  for (final a in items) {
    final f = await a.originFile;
    if (f != null) files.add(XFile(f.path));
  }
  if (files.isEmpty) return;
  await Share.shareXFiles(files); // newer share_plus: SharePlus.instance.share(ShareParams(files: files))
}

Future<bool> _copyOne(AssetEntity a, AlbumTarget t) async {
  try {
    if (t.existing != null) {
      return await PhotoManager.editor.copyAssetToPath(asset: a, pathEntity: t.existing!) != null;
    }
    final f = await a.originFile;
    if (f == null) return false;
    var title = await a.titleAsync;
    if (title.isEmpty) title = 'IMG_${a.id}.jpg';
    await PhotoManager.editor
        .saveImageWithPath(f.path, title: title, relativePath: 'Pictures/${t.newName}');
    return true;
  } catch (_) {
    return false;
  }
}

Future<int> _copy(List<AssetEntity> items, AlbumTarget t) async {
  var ok = 0;
  for (final a in items) {
    if (await _copyOne(a, t)) ok++;
  }
  return ok;
}

Future<int> _move(List<AssetEntity> items, AlbumTarget t) async {
  var ok = 0;
  final toDelete = <String>[];
  for (final a in items) {
    // Android 11+ can move natively into an existing album
    if (Platform.isAndroid && t.existing != null) {
      try {
        await PhotoManager.editor.android.moveAssetToAnother(entity: a, target: t.existing!);
        ok++;
        continue;
      } catch (_) {/* fall through to copy + delete */}
    }
    if (await _copyOne(a, t)) {
      ok++;
      toDelete.add(a.id);
    }
  }
  if (toDelete.isNotEmpty) await PhotoManager.editor.deleteWithIds(toDelete);
  return ok;
}

Future<int> _bin(List<AssetEntity> items) async {
  if (Platform.isAndroid) {
    try {
      await PhotoManager.editor.android.moveToTrash(items); // Android 11+, shows system prompt
      return items.length;
    } catch (_) {/* fall back below */}
  }
  final res = await PhotoManager.editor.deleteWithIds(items.map((e) => e.id).toList());
  return res.length;
}

// ════════════════════════════════════════════════════════════════════
//  METADATA SHEET
// ════════════════════════════════════════════════════════════════════
class _Meta {
  _Meta(this.name, this.path, this.bytes, this.mime, this.latlng);
  final String name, path, mime;
  final int bytes;
  final LatLng? latlng;
}

Future<_Meta> _loadMeta(AssetEntity a) async {
  final f = await a.originFile;
  final bytes = (f != null && await f.exists()) ? await f.length() : 0;
  return _Meta(
    await a.titleAsync,
    f?.path ?? (a.relativePath ?? ''),
    bytes,
    (await a.mimeTypeAsync) ?? '-',
    await a.latlngAsync(),
  );
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

Future<void> showMetadataSheet(BuildContext context, ActionColors c, AssetEntity a) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: c.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (_) => FutureBuilder<_Meta>(
      future: _loadMeta(a),
      builder: (ctx, snap) {
        final m = snap.data;
        final mp = (a.width * a.height) / 1e6;
        Widget row(IconData i, String k, String v) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(i, size: 20, color: c.accent),
                const SizedBox(width: 14),
                SizedBox(width: 86, child: Text(k, style: TextStyle(color: c.sub, fontSize: 13))),
                Expanded(
                    child: SelectableText(v,
                        style: TextStyle(color: c.text, fontSize: 14, fontWeight: FontWeight.w600))),
              ]),
            );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
            child: m == null
                ? const SizedBox(height: 160, child: Center(child: CircularProgressIndicator()))
                : SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('Details',
                          style: TextStyle(color: c.text, fontSize: 18, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 8),
                      row(Icons.image_outlined, 'Name', m.name.isEmpty ? '-' : m.name),
                      row(Icons.event_rounded, 'Taken',
                          DateFormat('EEE, d MMM yyyy • h:mm a').format(a.createDateTime)),
                      row(Icons.edit_calendar_rounded, 'Modified',
                          DateFormat('d MMM yyyy • h:mm a').format(a.modifiedDateTime)),
                      row(Icons.aspect_ratio_rounded, 'Resolution',
                          '${a.width} × ${a.height}  (${mp.toStringAsFixed(1)} MP)'),
                      row(Icons.sd_storage_rounded, 'Size', _fmtSize(m.bytes)),
                      row(Icons.category_outlined, 'Type', m.mime),
                      row(Icons.screen_rotation_rounded, 'Orientation', '${a.orientation}°'),
                      row(Icons.folder_open_rounded, 'Path', m.path.isEmpty ? '-' : m.path),
                      row(
                          Icons.place_outlined,
                          'Location',
                          (m.latlng == null || (m.latlng!.latitude == 0 && m.latlng!.longitude == 0))
                              ? 'Not available'
                              : '${m.latlng!.latitude.toStringAsFixed(5)}, ${m.latlng!.longitude.toStringAsFixed(5)}'),
                    ]),
                  ),
          ),
        );
      },
    ),
  );
}
