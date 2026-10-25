import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_cropper/image_cropper.dart';
import 'package:native_exif/native_exif.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:share_plus/share_plus.dart';

import '../core/vault_service.dart';
import '../db/database_helper.dart';
import '../db/vault_item_model.dart';
import 'video_player_screen.dart';

// ─────────────────────────────────────────────────────────────
// MODELS
// ─────────────────────────────────────────────────────────────

/// Any photo/video that can be shown in the viewer.
class PreviewItem {
  final String id;
  final bool isVideo;
  final ImageProvider Function() imageBuilder;
  final String heroTag;
  final String? title;
  final File? file; // used for Info, EXIF, rotation save
  final Future<File?> Function()? fileLoader; // gallery assets ki (originFile)
  final Map<String, String> details; // extra rows for Info sheet
  final Future<Map<String, String>> Function()? detailsLoader; // rich async Info
  final void Function(BuildContext context)? onPlay;
  final Object? data; // original object (VaultItem, AssetEntity, ...)
  final bool editable; // true => rotation save + EXIF edit allowed on [file]

  const PreviewItem({
    required this.id,
    required this.imageBuilder,
    required this.heroTag,
    this.isVideo = false,
    this.title,
    this.file,
    this.fileLoader,
    this.details = const {},
    this.detailsLoader,
    this.onPlay,
    this.data,
    this.editable = false,
  });

  factory PreviewItem.fromVault(
    VaultItem v, {
    bool trash = false,
    Future<Map<String, String>> Function()? detailsLoader,
  }) {
    final isVideo = v.type == 'video';
    final imagePath = (isVideo && v.thumbnailPath != null)
        ? v.thumbnailPath!
        : v.encryptedPath;
    return PreviewItem(
      id: '${v.id}',
      isVideo: isVideo,
      imageBuilder: () => FileImage(File(imagePath)),
      heroTag: trash ? 'bin_${v.id}' : 'vault_${v.id}',
      title: v.originalName,
      file: File(v.encryptedPath),
      details: {'Type': isVideo ? 'Video' : 'Photo'},
      detailsLoader: detailsLoader,
      editable: !isVideo && !trash,
      onPlay: (ctx) => Navigator.push(
        ctx,
        MaterialPageRoute(
          builder: (_) => VideoPlayerScreen(
            file: File(v.encryptedPath),
            title: v.originalName,
          ),
        ),
      ),
      data: v,
    );
  }
}

/// Throw this from PreviewAction.run when the user cancels / action fails.
class PreviewCancelled implements Exception {
  const PreviewCancelled();
}

/// A button shown in the dock (inDock = true) or in the More sheet.
class PreviewAction {
  final IconData icon;
  final String label;
  final Color color;
  final Future<void> Function(PreviewItem item) run;
  final bool inDock;
  final bool removesItem; // remove from viewer list after run
  final bool modifiesFile; // reload image in viewer after run
  final String? confirmTitle;
  final String? confirmMessage;

  const PreviewAction({
    required this.icon,
    required this.label,
    required this.run,
    this.color = const Color(0xFF65B7FF),
    this.inDock = true,
    this.removesItem = true,
    this.modifiesFile = false,
    this.confirmTitle,
    this.confirmMessage,
  });
}

/// Ready-made action sets. Add more for other screens here.
class PreviewActions {
  static const _blue = Color(0xFF65B7FF);
  static const _red = Color(0xFFFF647C);

  static List<PreviewAction> vault({bool trash = false}) {
    if (trash) {
      return [
        PreviewAction(
          icon: Icons.restore_rounded,
          label: 'Restore',
          color: _blue,
          run: (i) => DatabaseHelper.instance
              .setDeleted([(i.data as VaultItem).id!], false),
        ),
        PreviewAction(
          icon: Icons.delete_forever_rounded,
          label: 'Delete forever',
          color: _red,
          confirmTitle: 'Delete forever?',
          confirmMessage: 'This cannot be undone.',
          run: (i) => VaultService().deleteForever([i.data as VaultItem]),
        ),
      ];
    }

    return [
      // ── Dock ──
      PreviewAction(
        icon: Icons.ios_share_rounded,
        label: 'Export',
        color: _blue,
        run: (i) => VaultService().exportToGallery([i.data as VaultItem]),
      ),
      PreviewAction(
        icon: Icons.delete_outline_rounded,
        label: 'Move to bin',
        color: _red,
        run: (i) => DatabaseHelper.instance
            .setDeleted([(i.data as VaultItem).id!], true),
      ),

      // ── More sheet ──
      PreviewAction(
        icon: Icons.crop_rotate_rounded,
        label: 'Crop/Rotate',
        color: const Color(0xFFFFC857),
        inDock: false,
        removesItem: false,
        modifiesFile: true,
        run: _cropRotate,
      ),
      PreviewAction(
        icon: Icons.share_rounded,
        label: 'Share',
        color: const Color(0xFF7CE0B0),
        inDock: false,
        removesItem: false,
        run: (i) async {
          final v = i.data as VaultItem;
          await Share.shareXFiles(
            [XFile(v.encryptedPath, name: v.originalName)],
          );
        },
      ),
    ];
  }

  static Future<void> _cropRotate(PreviewItem i) async {
    final v = i.data as VaultItem;
    if (v.type == 'video') return;

    final cropped = await ImageCropper().cropImage(
      sourcePath: v.encryptedPath,
      compressFormat: ImageCompressFormat.jpg,
      compressQuality: 95,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop & Rotate',
          toolbarColor: const Color(0xFF101116),
          toolbarWidgetColor: Colors.white,
          backgroundColor: Colors.black,
          activeControlsWidgetColor: _blue,
          initAspectRatio: CropAspectRatioPreset.original,
          lockAspectRatio: false,
        ),
        IOSUiSettings(title: 'Crop & Rotate'),
      ],
    );
    if (cropped == null) throw const PreviewCancelled();

    await File(cropped.path).copy(v.encryptedPath); // original overwrite
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  }
}

// ─────────────────────────────────────────────────────────────
// BACKWARD-COMPATIBLE WRAPPER (existing calls keep working)
// ─────────────────────────────────────────────────────────────

class PhotoPreviewScreen extends StatelessWidget {
  final List<VaultItem> items;
  final int initialIndex;
  final bool trash;

  const PhotoPreviewScreen({
    super.key,
    required this.items,
    required this.initialIndex,
    this.trash = false,
  });

  @override
  Widget build(BuildContext context) {
    return UniversalPreviewScreen(
      items: items.map((e) => PreviewItem.fromVault(e, trash: trash)).toList(),
      initialIndex: initialIndex,
      actions: PreviewActions.vault(trash: trash),
      headerLabel: trash ? 'Recently Deleted' : 'Secure Viewer',
    );
  }
}

// ─────────────────────────────────────────────────────────────
// UNIVERSAL VIEWER
// ─────────────────────────────────────────────────────────────

class UniversalPreviewScreen extends StatefulWidget {
  final List<PreviewItem> items;
  final int initialIndex;
  final List<PreviewAction> actions;
  final String headerLabel;
  final VoidCallback? onChanged;

  const UniversalPreviewScreen({
    super.key,
    required this.items,
    required this.initialIndex,
    this.actions = const [],
    this.headerLabel = 'Viewer',
    this.onChanged,
  });

  @override
  State<UniversalPreviewScreen> createState() => _UniversalPreviewScreenState();
}

class _UniversalPreviewScreenState extends State<UniversalPreviewScreen> {
  static const _blue = Color(0xFF65B7FF);

  late final PageController _pc =
      PageController(initialPage: widget.initialIndex);
  late final List<PreviewItem> _items = List.of(widget.items);
  late int _index = widget.initialIndex.clamp(0, _items.length - 1);
  bool _chrome = true;
  bool _changed = false;
  bool _fill = false; // landscape photos -> rotate to fill portrait screen
  bool _saving = false;

  final Map<String, int> _turns = {}; // manual quarter turns per item
  final Map<String, int> _rev = {}; // bumps when file content changes
  final Map<String, Size> _dims = {}; // decoded image size per item
  final Set<String> _dimLoading = {};

  PreviewItem get _cur => _items[_index];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _warm(_index));
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  void _close() => Navigator.pop(context, _changed);

  // ── image helpers ──────────────────────────────────────────

  ImageProvider _provider(PreviewItem it) =>
      ResizeImage.resizeIfNeeded(2400, null, it.imageBuilder());

  /// Preload neighbours so swiping is instant.
  void _warm(int i) {
    if (!mounted) return;
    for (final j in [i - 1, i, i + 1]) {
      if (j < 0 || j >= _items.length) continue;
      final it = _items[j];
      precacheImage(_provider(it), context);
      _ensureDims(it);
    }
  }

  void _ensureDims(PreviewItem it) {
    if (_dims.containsKey(it.id) || _dimLoading.contains(it.id)) return;
    _dimLoading.add(it.id);
    final stream = _provider(it).resolve(ImageConfiguration.empty);
    late ImageStreamListener l;
    l = ImageStreamListener(
      (info, _) {
        _dims[it.id] =
            Size(info.image.width.toDouble(), info.image.height.toDouble());
        _dimLoading.remove(it.id);
        stream.removeListener(l);
        if (mounted) setState(() {});
      },
      onError: (_, __) {
        _dimLoading.remove(it.id);
        stream.removeListener(l);
      },
    );
    stream.addListener(l);
  }

  void _bump(String id) {
    _rev[id] = (_rev[id] ?? 0) + 1;
    _dims.remove(id);
    _dimLoading.remove(id);
    _turns[id] = 0;
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  }

  // ── rotation ───────────────────────────────────────────────

  int _quarterTurns(PreviewItem it) {
    final manual = _turns[it.id] ?? 0;
    final d = _dims[it.id];
    final autoFill = _fill &&
        d != null &&
        d.width > d.height &&
        MediaQuery.of(context).orientation == Orientation.portrait;
    return (manual + (autoFill ? 1 : 0)) % 4;
  }

  void _rotate(int dir) {
    final id = _cur.id;
    setState(() => _turns[id] = (((_turns[id] ?? 0) + dir) % 4 + 4) % 4);
    HapticFeedback.selectionClick();
  }

  bool get _needsSave =>
      _cur.editable && _cur.file != null && (_turns[_cur.id] ?? 0) != 0;

  Future<void> _saveRotation() async {
    final it = _cur;
    final q = _turns[it.id] ?? 0;
    final f = it.file;
    if (q == 0 || f == null || _saving) return;
    setState(() => _saving = true);
    try {
      final bytes = await f.readAsBytes();
      final out = await compute(_rotateBytes, <Object>[bytes, q]);
      if (out == null) throw 'decode failed';
      await f.writeAsBytes(out, flush: true);
      if (!mounted) return;
      setState(() => _bump(it.id));
      _changed = true;
      widget.onChanged?.call();
      _toast('Rotation saved');
    } catch (_) {
      _toast('Save cheyyalekapoyam');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── actions ────────────────────────────────────────────────

  Future<void> _run(PreviewAction a) async {
    final item = _cur;
    if (a.confirmMessage != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF16181F),
          title: Text(a.confirmTitle ?? a.label,
              style: const TextStyle(color: Colors.white)),
          content: Text(a.confirmMessage!,
              style: const TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(a.label, style: TextStyle(color: a.color)),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    try {
      await a.run(item);
    } on PreviewCancelled {
      return;
    }
    if (!mounted) return;
    _changed = true;
    widget.onChanged?.call();

    if (!a.removesItem) {
      setState(() {
        if (a.modifiesFile) _bump(item.id);
      });
      return;
    }

    if (_items.length <= 1) {
      _close();
      return;
    }
    setState(() {
      _items.removeAt(_index);
      if (_index >= _items.length) _index = _items.length - 1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pc.hasClients) _pc.jumpToPage(_index);
      _warm(_index);
    });
  }

  void _toast(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(t),
        duration: const Duration(milliseconds: 1600),
      ));
  }

  Future<void> _editExif() async {
    final it = _cur;
    final f = it.file;
    if (f == null) return;
    final res = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ExifEditor(file: f),
    );
    if (res == true && mounted) {
      setState(() => _bump(it.id));
      _changed = true;
      widget.onChanged?.call();
      _toast('Metadata updated');
    }
  }

  // ── sheets ─────────────────────────────────────────────────

  void _showMore() {
    final extra = widget.actions.where((a) => !a.inDock).toList();
    final it = _cur;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: _glass(
            radius: BorderRadius.circular(26),
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
            child: Wrap(
              alignment: WrapAlignment.start,
              children: [
                _sheetTile(Icons.info_outline_rounded, 'Info', _blue, () {
                  Navigator.pop(ctx);
                  _showInfo();
                }),
                if (it.editable && it.file != null && !it.isVideo)
                  _sheetTile(Icons.edit_note_rounded, 'Edit EXIF',
                      const Color(0xFFFFC857), () {
                    Navigator.pop(ctx);
                    _editExif();
                  }),
                _sheetTile(Icons.copy_rounded, 'Copy name',
                    const Color(0xFF7CE0B0), () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: _cur.title ?? ''));
                  _toast('Name copied');
                }),
                for (final a in extra)
                  _sheetTile(a.icon, a.label, a.color, () {
                    Navigator.pop(ctx);
                    _run(a);
                  }),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sheetTile(
      IconData icon, String label, Color color, VoidCallback onTap) {
    return SizedBox(
      width: (MediaQuery.of(context).size.width - 28 - 16) / 4,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: color.withOpacity(0.3)),
                  ),
                  child: Icon(icon, color: color, size: 23),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _fmtSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<List<MapEntry<String, String>>> _loadInfo(PreviewItem it) async {
    final rows = <MapEntry<String, String>>[];
    bool has(String k) => rows.any((e) => e.key == k);

    if (it.detailsLoader != null) {
      try {
        rows.addAll((await it.detailsLoader!()).entries);
      } catch (_) {}
    } else {
      rows.add(MapEntry('Name', it.title ?? '-'));
      rows.add(MapEntry('Position', '${_index + 1} of ${_items.length}'));
      rows.addAll(it.details.entries);
    }

    final f = it.file ?? await it.fileLoader?.call();
    if (f != null && await f.exists()) {
      if (!has('Size')) rows.add(MapEntry('Size', _fmtSize(await f.length())));
      if (!it.isVideo) {
        final s = await _readSize(f);
        if (s != null && !has('Resolution')) {
          final mp = (s.width * s.height / 1e6).toStringAsFixed(1);
          rows.add(MapEntry('Resolution',
              '${s.width.toInt()} × ${s.height.toInt()}  ($mp MP)'));
        }
        for (final e in await _readExif(f)) {
          if (!has(e.key)) rows.add(e);
        }
      }
      rows.add(MapEntry('Path', f.path));
    }
    return rows;
  }

  void _showInfo() {
    final item = _cur;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: _glass(
            radius: BorderRadius.circular(26),
            padding: const EdgeInsets.all(18),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.72,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Details',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 14),
                    FutureBuilder<List<MapEntry<String, String>>>(
                      future: _loadInfo(item),
                      builder: (_, s) {
                        if (s.connectionState != ConnectionState.done) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }
                        final rows = s.data ?? const [];
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final e in rows)
                              e.key == 'Path'
                                  ? _pathRow(e.value)
                                  : _infoRow(e.key, e.value),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _infoRow(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 92,
              child: Text(k,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.55),
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ),
            Expanded(
              child: Text(v,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
            ),
          ],
        ),
      );

  /// Tap = open folder in default file manager, long-press = copy path.
  Widget _pathRow(String path) => InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          final ok = await _openFolder(path);
          if (!ok) {
            await Clipboard.setData(ClipboardData(text: path));
            _toast('Folder open avvaledu (private folder) — path copy chesa');
          }
        },
        onLongPress: () {
          Clipboard.setData(ClipboardData(text: path));
          _toast('Path copied');
        },
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 92,
                child: Text('Path',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.55),
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(path,
                        style: const TextStyle(
                            color: _blue, fontSize: 13.5, height: 1.25)),
                    const SizedBox(height: 3),
                    Text('Tap: file manager • Long press: copy',
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.4),
                            fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  // ── shared widgets ─────────────────────────────────────────

  Widget _dockButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Semantics(
        button: true,
        label: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.13),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: color.withOpacity(0.28)),
                    ),
                    child: Icon(icon, color: color, size: 22),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.92),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.25,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _topIcon(IconData icon, VoidCallback onTap,
      {String? tip, bool active = false}) {
    return IconButton(
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
      icon: Icon(icon, color: active ? _blue : Colors.white, size: 22),
    );
  }

  // ── build ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const Scaffold(backgroundColor: Colors.black);

    final media = MediaQuery.of(context);
    final item = _cur;
    final dockActions = widget.actions.where((a) => a.inDock).toList();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF050609),
        extendBodyBehindAppBar: true,
        extendBody: true,
        body: Stack(
          fit: StackFit.expand,
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.topCenter,
                  radius: 1.15,
                  colors: [
                    Color(0xFF202638),
                    Color(0xFF090A0F),
                    Color(0xFF030407),
                  ],
                  stops: [0, 0.55, 1],
                ),
              ),
            ),

            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _chrome = !_chrome),
              child: PhotoViewGallery.builder(
                pageController: _pc,
                itemCount: _items.length,
                scrollPhysics: const BouncingScrollPhysics(),
                onPageChanged: (i) {
                  setState(() => _index = i);
                  _warm(i);
                },
                backgroundDecoration:
                    const BoxDecoration(color: Colors.transparent),
                builder: (_, i) {
                  final it = _items[i];
                  final rev = _rev[it.id] ?? 0;
                  final dims = _dims[it.id];
                  if (dims == null) {
                    WidgetsBinding.instance
                        .addPostFrameCallback((_) => _ensureDims(it));
                  }
                  final q = _quarterTurns(it);
                  final base = dims ?? media.size;
                  final box = q.isOdd ? Size(base.height, base.width) : base;

                  return PhotoViewGalleryPageOptions.customChild(
                    childSize: box,
                    initialScale: PhotoViewComputedScale.contained,
                    minScale: PhotoViewComputedScale.contained,
                    maxScale: PhotoViewComputedScale.covered * 3,
                    heroAttributes: PhotoViewHeroAttributes(tag: it.heroTag),
                    child: RepaintBoundary(
                      child: SizedBox(
                        width: box.width,
                        height: box.height,
                        child: RotatedBox(
                          quarterTurns: q,
                          child: Image(
                            key: ValueKey('${it.id}#$rev'),
                            image: _provider(it),
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                            filterQuality: FilterQuality.medium,
                            errorBuilder: (_, __, ___) => const Center(
                              child: Icon(
                                Icons.broken_image_outlined,
                                color: Colors.white54,
                                size: 54,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

            if (item.isVideo && item.onPlay != null)
              Center(
                child: GestureDetector(
                  onTap: () => item.onPlay!(context),
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.42),
                      shape: BoxShape.circle,
                      border:
                          Border.all(color: Colors.white.withOpacity(0.35)),
                      boxShadow: const [
                        BoxShadow(color: Colors.black45, blurRadius: 20),
                      ],
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 52,
                    ),
                  ),
                ),
              ),

            // Top bar
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                offset: _chrome ? Offset.zero : const Offset(0, -1.2),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: _chrome ? 1 : 0,
                  child: IgnorePointer(
                    ignoring: !_chrome,
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                        child: _glass(
                          radius: BorderRadius.circular(22),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 5),
                          child: Row(
                            children: [
                              IconButton(
                                tooltip: 'Back',
                                onPressed: _close,
                                icon: const Icon(Icons.arrow_back_rounded,
                                    color: Colors.white),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      widget.headerLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.65),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 1.2,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${_index + 1}  /  ${_items.length}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 17,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.8,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (!item.isVideo) ...[
                                _topIcon(Icons.rotate_left_rounded,
                                    () => _rotate(-1),
                                    tip: 'Rotate left'),
                                _topIcon(Icons.rotate_right_rounded,
                                    () => _rotate(1),
                                    tip: 'Rotate right'),
                                _topIcon(
                                  Icons.stay_current_landscape_rounded,
                                  () => setState(() => _fill = !_fill),
                                  tip: 'Landscape fill',
                                  active: _fill,
                                ),
                              ] else
                                const Padding(
                                  padding: EdgeInsets.only(right: 12),
                                  child: Icon(Icons.videocam_rounded,
                                      color: Colors.white70, size: 20),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Bottom dock (+ save-rotation pill)
            Positioned(
              left: 14,
              right: 14,
              bottom: media.padding.bottom + 12,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                offset: _chrome ? Offset.zero : const Offset(0, 1.5),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: _chrome ? 1 : 0,
                  child: IgnorePointer(
                    ignoring: !_chrome,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_needsSave)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: GestureDetector(
                              onTap: _saveRotation,
                              child: _glass(
                                radius: BorderRadius.circular(30),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 18, vertical: 11),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _saving
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2),
                                          )
                                        : const Icon(Icons.check_rounded,
                                            color: _blue, size: 20),
                                    const SizedBox(width: 8),
                                    const Text('Save rotation',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w700)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        _glass(
                          radius: BorderRadius.circular(26),
                          padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
                          child: Row(
                            children: [
                              for (final a in dockActions)
                                _dockButton(
                                  icon: a.icon,
                                  label: a.label,
                                  color: a.color,
                                  onTap: () => _run(a),
                                ),
                              _dockButton(
                                icon: Icons.more_horiz_rounded,
                                label: 'More',
                                color: Colors.white,
                                onTap: _showMore,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// EXIF EDITOR
// ─────────────────────────────────────────────────────────────

class _ExifEditor extends StatefulWidget {
  final File file;
  const _ExifEditor({required this.file});

  @override
  State<_ExifEditor> createState() => _ExifEditorState();
}

class _ExifEditorState extends State<_ExifEditor> {
  final _desc = TextEditingController();
  final _artist = TextEditingController();
  final _make = TextEditingController();
  final _model = TextEditingController();
  final _lat = TextEditingController();
  final _lon = TextEditingController();
  DateTime? _date;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_desc, _artist, _make, _model, _lat, _lon]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    Exif? exif;
    try {
      exif = await Exif.fromPath(widget.file.path);
      final a = await exif.getAttributes() ?? {};
      String s(String k) => '${a[k] ?? ''}'.trim();
      _desc.text = s('ImageDescription');
      _artist.text = s('Artist');
      _make.text = s('Make');
      _model.text = s('Model');
      _date = _parseExifDate(
          s('DateTimeOriginal').isNotEmpty ? s('DateTimeOriginal') : s('DateTime'));
      final ll = await exif.getLatLong();
      if (ll != null) {
        _lat.text = ll.latitude.toStringAsFixed(6);
        _lon.text = ll.longitude.toStringAsFixed(6);
      }
    } catch (_) {
    } finally {
      await exif?.close();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pickDate() async {
    final now = _date ?? DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(1970),
      lastDate: DateTime(2100),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now),
    );
    if (t == null) return;
    setState(() => _date = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    Exif? exif;
    try {
      exif = await Exif.fromPath(widget.file.path);
      final m = <String, Object>{};
      void put(String k, String v) {
        if (v.trim().isNotEmpty) m[k] = v.trim();
      }

      put('ImageDescription', _desc.text);
      put('Artist', _artist.text);
      put('Make', _make.text);
      put('Model', _model.text);
      if (_date != null) {
        final s = _fmtExifDate(_date!);
        m['DateTimeOriginal'] = s;
        m['DateTimeDigitized'] = s;
        m['DateTime'] = s;
      }

      final la = double.tryParse(_lat.text.trim());
      final lo = double.tryParse(_lon.text.trim());
      if (la != null && lo != null && la.abs() <= 90 && lo.abs() <= 180) {
        m.addAll(_gpsAttrs(la, lo));
      }
      if (m.isNotEmpty) await exif.writeAttributes(m);

      await exif.close();
      exif = null;
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      await exif?.close();
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('EXIF write avvaledu (JPEG ki matrame)')),
        );
      }
    }
  }

  Future<void> _strip() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16181F),
        title: const Text('Remove all metadata?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'Location, camera, date anni delete avthayi. Image re-save avthundi.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove',
                  style: TextStyle(color: Color(0xFFFF647C)))),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final bytes = await widget.file.readAsBytes();
      final out = await compute(_stripBytes, bytes);
      if (out == null) throw 'decode';
      await widget.file.writeAsBytes(out, flush: true);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Metadata remove avvaledu')),
        );
      }
    }
  }

  Widget _field(TextEditingController c, String label,
      {TextInputType? type}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: c,
        keyboardType: type,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: Colors.white.withOpacity(0.6)),
          isDense: true,
          filled: true,
          fillColor: Colors.white.withOpacity(0.06),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final kb = mq.viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, 14, 14, 14 + kb),
        child: _glass(
          radius: BorderRadius.circular(26),
          padding: const EdgeInsets.all(18),
          child: ConstrainedBox(
            constraints:
                BoxConstraints(maxHeight: (mq.size.height - kb) * 0.78),
            child: _loading
                ? const SizedBox(
                    height: 120,
                    child: Center(child: CircularProgressIndicator()),
                  )
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Edit EXIF',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(height: 14),
                        InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: _pickDate,
                          child: Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 14),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.06),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.event_rounded,
                                    color: Color(0xFFFFC857), size: 20),
                                const SizedBox(width: 10),
                                Text(
                                  _date == null
                                      ? 'Date taken (tap to set)'
                                      : _fmtExifDate(_date!),
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ],
                            ),
                          ),
                        ),
                        _field(_desc, 'Description'),
                        _field(_artist, 'Artist'),
                        Row(children: [
                          Expanded(child: _field(_make, 'Make')),
                          const SizedBox(width: 10),
                          Expanded(child: _field(_model, 'Model')),
                        ]),
                        Row(children: [
                          Expanded(
                              child: _field(_lat, 'Latitude',
                                  type: const TextInputType.numberWithOptions(
                                      decimal: true, signed: true))),
                          const SizedBox(width: 10),
                          Expanded(
                              child: _field(_lon, 'Longitude',
                                  type: const TextInputType.numberWithOptions(
                                      decimal: true, signed: true))),
                        ]),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _busy ? null : _strip,
                                icon: const Icon(Icons.layers_clear_rounded,
                                    size: 18),
                                label: const Text('Strip all'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _busy ? null : _save,
                                icon: _busy
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2))
                                    : const Icon(Icons.save_rounded, size: 18),
                                label: const Text('Save'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// TOP-LEVEL HELPERS
// ─────────────────────────────────────────────────────────────

Widget _glass({
  required Widget child,
  BorderRadius radius = const BorderRadius.all(Radius.circular(24)),
  EdgeInsetsGeometry padding = EdgeInsets.zero,
}) {
  return ClipRRect(
    borderRadius: radius,
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: const Color(0xCC101116),
          borderRadius: radius,
          border: Border.all(color: Colors.white.withOpacity(0.13)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.24),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: child,
      ),
    ),
  );
}

/// Opens the file's folder in the default Android file manager.
Future<bool> _openFolder(String filePath) async {
  if (!Platform.isAndroid) return false;
  final dir = File(filePath).parent.path;
  const root = '/storage/emulated/0/';
  if (!dir.startsWith(root)) return false;
  final rel = dir.substring(root.length);
  final uri =
      'content://com.android.externalstorage.documents/document/primary%3A${Uri.encodeComponent(rel)}';
  try {
    await AndroidIntent(
      action: 'android.intent.action.VIEW',
      data: uri,
      type: 'vnd.android.document/directory',
    ).launch();
    return true;
  } catch (_) {
    return false;
  }
}

/// Reads dimensions without fully decoding the image.
Future<Size?> _readSize(File f) async {
  try {
    final buf = await ImmutableBuffer.fromUint8List(await f.readAsBytes());
    final d = await ImageDescriptor.encoded(buf);
    final s = Size(d.width.toDouble(), d.height.toDouble());
    d.dispose();
    buf.dispose();
    return s;
  } catch (_) {
    return null;
  }
}

Future<List<MapEntry<String, String>>> _readExif(File f) async {
  final out = <MapEntry<String, String>>[];
  Exif? e;
  try {
    e = await Exif.fromPath(f.path);
    final a = await e.getAttributes() ?? {};
    String? g(String k) {
      final v = a[k];
      if (v == null) return null;
      final s = '$v'.trim();
      return s.isEmpty ? null : s;
    }

    final cam = [g('Make'), g('Model')].whereType<String>().join(' ');
    if (cam.isNotEmpty) out.add(MapEntry('Camera', cam));
    final d = g('DateTimeOriginal') ?? g('DateTime');
    if (d != null) out.add(MapEntry('Taken', d));
    final fn = g('FNumber');
    if (fn != null) out.add(MapEntry('Aperture', 'f/$fn'));
    final ex = g('ExposureTime');
    if (ex != null) out.add(MapEntry('Shutter', '$ex s'));
    final iso = g('ISOSpeedRatings') ?? g('PhotographicSensitivity');
    if (iso != null) out.add(MapEntry('ISO', iso));
    final fl = g('FocalLength');
    if (fl != null) out.add(MapEntry('Focal length', fl));
    final desc = g('ImageDescription');
    if (desc != null) out.add(MapEntry('Description', desc));
    final art = g('Artist');
    if (art != null) out.add(MapEntry('Artist', art));
    final ll = await e.getLatLong();
    if (ll != null) {
      out.add(MapEntry('Location',
          '${ll.latitude.toStringAsFixed(5)}, ${ll.longitude.toStringAsFixed(5)}'));
    }
  } catch (_) {
  } finally {
    await e?.close();
  }
  return out;
}

/// GPS tags ni EXIF format (deg/1,min/1,sec/10000) lo ichestundi.
Map<String, Object> _gpsAttrs(double lat, double lon) {
  String dms(double v) {
    v = v.abs();
    final d = v.floor();
    final mFull = (v - d) * 60;
    final m = mFull.floor();
    final s = ((mFull - m) * 60 * 10000).round();
    return '$d/1,$m/1,$s/10000';
  }

  return {
    'GPSLatitude': dms(lat),
    'GPSLatitudeRef': lat >= 0 ? 'N' : 'S',
    'GPSLongitude': dms(lon),
    'GPSLongitudeRef': lon >= 0 ? 'E' : 'W',
  };
}

String _fmtExifDate(DateTime d) {
  String p(int n) => n.toString().padLeft(2, '0');
  return '${d.year}:${p(d.month)}:${p(d.day)} ${p(d.hour)}:${p(d.minute)}:${p(d.second)}';
}

DateTime? _parseExifDate(String s) {
  // "2024:05:17 14:03:22"
  final m = RegExp(r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})')
      .firstMatch(s);
  if (m == null) return null;
  int g(int i) => int.parse(m.group(i)!);
  try {
    return DateTime(g(1), g(2), g(3), g(4), g(5), g(6));
  } catch (_) {
    return null;
  }
}

// ── isolate workers (UI lag undadu) ──

Uint8List _encodeLike(Uint8List src, img.Image im) {
  final fmt = img.findFormatForData(src);
  if (fmt == img.ImageFormat.png) {
    return Uint8List.fromList(img.encodePng(im));
  }
  return Uint8List.fromList(img.encodeJpg(im, quality: 95));
}

Uint8List? _rotateBytes(List<Object> args) {
  final bytes = args[0] as Uint8List;
  final q = args[1] as int;
  var im = img.decodeImage(bytes);
  if (im == null) return null;
  im = img.bakeOrientation(im);
  im = img.copyRotate(im, angle: 90.0 * q);
  return _encodeLike(bytes, im);
}

Uint8List? _stripBytes(Uint8List bytes) {
  var im = img.decodeImage(bytes);
  if (im == null) return null;
  im = img.bakeOrientation(im);
  im.exif = img.ExifData();
  return _encodeLike(bytes, im);
}