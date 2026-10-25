import 'dart:io';
import 'dart:ui' show ImageFilter, lerpDouble;
import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../core/theme_provider.dart';
import '../core/vault_service.dart';
import '../db/database_helper.dart';
import 'photo_preview_screen.dart';
import 'video_player_screen.dart';

// ════════════════════════════════════════════════════════════════════
//  UI COMPONENTS (Glass, Buttons, Checkbox)
// ════════════════════════════════════════════════════════════════════
class _Glass extends StatelessWidget {
  const _Glass({required this.p, required this.child, this.radius = 24, this.blur = 22, this.border});
  final AppPalette p;
  final Widget child;
  final double radius, blur;
  final BoxBorder? border;

  @override
  Widget build(BuildContext context) {
    final br = radius > 0 ? BorderRadius.circular(radius) : null;
    return ClipRRect(
      borderRadius: br ?? BorderRadius.zero,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(color: p.bar, borderRadius: br, border: border ?? (radius > 0 ? Border.all(color: p.border) : null)),
          child: child,
        ),
      ),
    );
  }
}

class _Press extends StatefulWidget {
  const _Press({required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;
  @override
  State<_Press> createState() => _PressState();
}

class _PressState extends State<_Press> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) { setState(() => _down = false); HapticFeedback.selectionClick(); widget.onTap(); },
      onTapCancel: () => setState(() => _down = false),
      child: AnimatedScale(scale: _down ? 0.88 : 1, duration: const Duration(milliseconds: 110), curve: Curves.easeOut, child: widget.child),
    );
  }
}

class _DockBtn extends StatelessWidget {
  const _DockBtn({required this.icon, required this.label, required this.color, required this.p, required this.onTap});
  final IconData icon;
  final String label;
  final Color color;
  final AppPalette p;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _Press(
      onTap: onTap,
      child: SizedBox(
        width: 58,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 42, height: 42,
            decoration: BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [color.withValues(alpha: 0.30), color.withValues(alpha: 0.10)]), border: Border.all(color: color.withValues(alpha: 0.35))),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 5),
          Text(label, style: TextStyle(color: p.text.withValues(alpha: 0.85), fontSize: 10, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

class _Check extends StatelessWidget {
  const _Check({required this.on, required this.p});
  final bool on;
  final AppPalette p;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180), curve: Curves.easeOutCubic,
      width: 24, height: 24,
      decoration: BoxDecoration(shape: BoxShape.circle, color: on ? p.accent : Colors.black.withValues(alpha: 0.28), border: on ? null : Border.all(color: Colors.white, width: 1.6)),
      child: AnimatedScale(scale: on ? 1 : 0, duration: const Duration(milliseconds: 220), curve: Curves.easeOutBack, child: const Icon(Icons.check_rounded, size: 16, color: Colors.white)),
    );
  }
}

HeroFlightShuttleBuilder _shuttle(ImageProvider img) {
  return (ctx, anim, dir, fromCtx, toCtx) => AnimatedBuilder(
        animation: anim,
        builder: (_, __) => ClipRRect(
          borderRadius: BorderRadius.circular(lerpDouble(11, 0, Curves.easeOut.transform(dir == HeroFlightDirection.push ? anim.value : 1 - anim.value))!),
          child: Image(image: img, fit: BoxFit.cover, gaplessPlayback: true),
        ),
      );
}

// ════════════════════════════════════════════════════════════════════
//  MAIN SCREEN
// ════════════════════════════════════════════════════════════════════
class DeviceAlbumScreen extends StatefulWidget {
  final AssetPathEntity album;
  final String albumName;
  const DeviceAlbumScreen({super.key, required this.album, required this.albumName});

  @override
  State<DeviceAlbumScreen> createState() => _DeviceAlbumScreenState();
}

class _DeviceAlbumScreenState extends State<DeviceAlbumScreen> {
  List<AssetEntity> _items = [];
  final Set<String> _selected = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAlbumAssets();
  }

  Future<void> _loadAlbumAssets() async {
    try {
      final count = await widget.album.assetCountAsync;

      final assets = await widget.album.getAssetListRange(
        start: 0,
        end: count,
      );

      // Newest photos/videos first.
      assets.sort((a, b) {
        final dateCompare = b.createDateTime.compareTo(a.createDateTime);
        if (dateCompare == 0) return b.id.compareTo(a.id);
        return dateCompare;
      });

      if (!mounted) return;

      setState(() {
        _items = assets;
        _loading = false;
      });
    } catch (e, stackTrace) {
      debugPrint('Load album assets error: $e');
      debugPrintStack(stackTrace: stackTrace);

      if (!mounted) return;

      setState(() {
        _items = [];
        _loading = false;
      });
    }
  }

  void _toggle(AssetEntity a) {
    setState(() {
      _selected.contains(a.id) ? _selected.remove(a.id) : _selected.add(a.id);
    });
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  /// Single-item operations kosam simple spinner.
  Future<T> _busy<T>(Future<T> Function() job) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      return await job();
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  // ── ALBUM INFO POPUP ──
  Future<void> _showAlbumStats(BuildContext context, AppPalette p) {
    return showModalBottomSheet<void>(
      context: context, backgroundColor: p.surface, isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => FutureBuilder<Map<String, int>>(
        future: () async {
          int pCount = 0, vCount = 0;
          for (final item in _items) {
            item.type == AssetType.video ? vCount++ : pCount++;
          }
          return {'Photos': pCount, 'Videos': vCount, 'Total Items': pCount + vCount};
        }(),
        builder: (ctx, snap) {
          final m = snap.data;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
              child: m == null
                  ? SizedBox(height: 120, child: Center(child: CircularProgressIndicator(color: p.accent)))
                  : Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('${widget.albumName} Info', style: TextStyle(color: p.text, fontSize: 20, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 20),
                      for (final e in m.entries)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Row(children: [
                            Icon(e.key == 'Photos' ? Icons.image_outlined : e.key == 'Videos' ? Icons.play_circle_outline : Icons.storage_rounded, color: p.accent, size: 24),
                            const SizedBox(width: 12),
                            Expanded(child: Text(e.key, style: TextStyle(color: p.sub, fontSize: 15, fontWeight: FontWeight.w600))),
                            Text('${e.value}', style: TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.w700)),
                          ]),
                        ),
                    ]),
            ),
          );
        },
      ),
    );
  }

  // ── CONFIRM DIALOG ──
  Future<bool> _showConfirmDialog(AppPalette p, String title, String content, String actionText) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        title: Text(title, style: TextStyle(color: p.text, fontWeight: FontWeight.bold)),
        content: Text(content, style: TextStyle(color: p.sub, fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: p.text))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(actionText, style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold))),
        ],
      ),
    );
    return res ?? false;
  }

  // ── LOCAL ALBUM PICKER ──
  Future<AssetPathEntity?> _showLocalAlbumPicker(AppPalette p, String title) async {
    final albums = await PhotoManager.getAssetPathList(type: RequestType.image | RequestType.video);
    final validAlbums = albums.where((a) => a.id != widget.album.id && !a.isAll).toList();

    if (!mounted) return null;
    return showDialog<AssetPathEntity>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        title: Text(title, style: TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.w700)),
        content: SizedBox(
          width: double.maxFinite, height: 300,
          child: ListView.builder(
            physics: const BouncingScrollPhysics(),
            itemCount: validAlbums.length,
            itemBuilder: (_, i) => ListTile(
              title: Text(validAlbums[i].name, style: TextStyle(color: p.text)),
              leading: Icon(Icons.folder_outlined, color: p.accent),
              onTap: () => Navigator.pop(ctx, validAlbums[i]),
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
      ),
    );
  }

  // ── VAULT ALBUM PICKER ──
  Future<String?> _showVaultAlbumPicker(AppPalette p, String title) async {
    final albums = (await DatabaseHelper.instance.fetchAlbums()).map((e) => e['albumName'] as String).toList();
    final ctrl = TextEditingController();
    if (!mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        title: Text(title, style: TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.w700)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: ctrl, style: TextStyle(color: p.text), decoration: InputDecoration(hintText: 'కొత్త ఆల్బమ్ పేరు', hintStyle: TextStyle(color: p.sub))),
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final a in albums) ActionChip(backgroundColor: p.bg2, side: BorderSide(color: p.border), label: Text(a, style: TextStyle(color: p.text)), onPressed: () => Navigator.pop(ctx, a)),
          ]),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim().isEmpty ? 'My_Photos' : ctrl.text.trim()), child: const Text('Select')),
        ],
      ),
    );
  }

  double _operationProgress = 0;
  String _operationLabel = 'Preparing...';
  StateSetter? _progressDialogSetState;

  void _showOperationProgress(String title) {
    _operationProgress = 0;
    _operationLabel = title;
    _progressDialogSetState = null;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          _progressDialogSetState = setDialogState;
          return AlertDialog(
            backgroundColor: context.read<ThemeProvider>().p.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
            title: Text(title, style: TextStyle(color: context.read<ThemeProvider>().p.text, fontWeight: FontWeight.w700)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_operationLabel, style: TextStyle(color: context.read<ThemeProvider>().p.sub, fontSize: 13)),
                const SizedBox(height: 14),
                LinearProgressIndicator(value: _operationProgress, minHeight: 7),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text('${(_operationProgress * 100).round()}%',
                    style: TextStyle(color: context.read<ThemeProvider>().p.text, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _updateOperationProgress(int completed, int total, String label) {
    _operationProgress = total <= 0 ? 1 : completed / total;
    _operationLabel = '$label ($completed/$total)';
    _progressDialogSetState?.call(() {});
  }

  void _closeOperationProgress() {
    _progressDialogSetState = null;
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  // ── BULK ACTIONS (grid selection) ──
  Future<void> _shareSelected() async {
    final chosen = _items.where((a) => _selected.contains(a.id)).toList();
    if (chosen.isEmpty) return;
    final files = <XFile>[];
    for (final a in chosen) {
      final file = await a.originFile;
      if (file != null && await file.exists()) files.add(XFile(file.path));
    }
    if (files.isNotEmpty) {
      await Share.shareXFiles(files);
      if (mounted) setState(() => _selected.clear());
    }
  }

  Future<void> _deleteSelected(AppPalette p) async {
    final chosen = _items.where((a) => _selected.contains(a.id)).toList();
    if (chosen.isEmpty) return;
    if (!await _showConfirmDialog(p, 'డిలీట్ చేయాలా?', 'ఈ ${chosen.length} ఐటెమ్స్ గ్యాలరీ నుండి డిలీట్ చేయబడతాయి.', 'Delete')) return;

    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    await PhotoManager.editor.deleteWithIds(chosen.map((e) => e.id).toList());

    if (mounted) {
      Navigator.pop(context);
      setState(() => _selected.clear());
      _loadAlbumAssets();
    }
  }

  Future<void> _moveToVaultSelected(AppPalette p) async {
    final chosen = _items.where((a) => _selected.contains(a.id)).toList();
    if (chosen.isEmpty) return;
    final target = await _showVaultAlbumPicker(p, 'వాల్ట్ లోకి మార్చు (Vault)');
    if (target == null || !mounted) return;
    if (!await _showConfirmDialog(p, 'Move to Vault', 'ఈ ${chosen.length} ఫోటోలను వాల్ట్ లోకి మార్చాలా?', 'Move')) return;

    _showOperationProgress('Moving to Vault');
    final vault = VaultService();
    final idsToDelete = <String>[];
    int ok = 0;
    try {
      for (int i = 0; i < chosen.length; i++) {
        final a = chosen[i];
        if (await vault.hideAsset(a, target)) {
          ok++;
          idsToDelete.add(a.id);
        }
        _updateOperationProgress(i + 1, chosen.length, 'Moving items');
      }
      if (idsToDelete.isNotEmpty) {
        _operationLabel = 'Removing originals...';
        _progressDialogSetState?.call(() {});
        await PhotoManager.editor.deleteWithIds(idsToDelete);
      }
    } finally {
      _closeOperationProgress();
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$ok items moved to Vault 🔒')));
      setState(() => _selected.clear());
      _loadAlbumAssets();
    }
  }

  Future<void> _copyLocalSelected(AppPalette p) async {
    final chosen = _items.where((a) => _selected.contains(a.id)).toList();
    if (chosen.isEmpty) return;
    final target = await _showLocalAlbumPicker(p, 'Copy to Album');
    if (target == null || !mounted) return;

    _showOperationProgress('Copying to ${target.name}');
    int ok = 0;
    try {
      for (int i = 0; i < chosen.length; i++) {
        final a = chosen[i];
        final newAsset = await PhotoManager.editor.copyAssetToPath(asset: a, pathEntity: target);
        if (newAsset != null) ok++;
        _updateOperationProgress(i + 1, chosen.length, 'Copying items');
      }
    } finally {
      _closeOperationProgress();
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$ok items copied to ${target.name} 📄')));
      setState(() => _selected.clear());
    }
  }

  Future<void> _moveLocalSelected(AppPalette p) async {
    final chosen = _items.where((a) => _selected.contains(a.id)).toList();
    if (chosen.isEmpty) return;
    final target = await _showLocalAlbumPicker(p, 'Move to Album');
    if (target == null || !mounted) return;
    if (!await _showConfirmDialog(p, 'Move Photos', 'ఈ ${chosen.length} ఐటెమ్స్ ని ${target.name} లోకి మూవ్ చేయాలా?', 'Move')) return;

    _showOperationProgress('Moving to ${target.name}');
    int ok = 0;
    final idsToDelete = <String>[];
    try {
      for (int i = 0; i < chosen.length; i++) {
        final a = chosen[i];
        final newAsset = await PhotoManager.editor.copyAssetToPath(asset: a, pathEntity: target);
        if (newAsset != null) { ok++; idsToDelete.add(a.id); }
        _updateOperationProgress(i + 1, chosen.length, 'Moving items');
      }
      if (idsToDelete.isNotEmpty) {
        _operationLabel = 'Removing originals...';
        _progressDialogSetState?.call(() {});
        await PhotoManager.editor.deleteWithIds(idsToDelete);
      }
    } finally {
      _closeOperationProgress();
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$ok items moved to ${target.name} 🚀')));
      setState(() => _selected.clear());
      _loadAlbumAssets();
    }
  }

  // ════════════════════════════════════════════════════════════════
  //  UNIVERSAL PREVIEW INTEGRATION
  // ════════════════════════════════════════════════════════════════
  Future<void> _openPreview(int idx) async {
    final p = context.read<ThemeProvider>().p;

    final changed = await Navigator.of(context).push<bool>(PageRouteBuilder<bool>(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 420),
      reverseTransitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (_, __, ___) => UniversalPreviewScreen(
        items: _items.map(_toPreviewItem).toList(),
        initialIndex: idx,
        headerLabel: widget.albumName,
        actions: _previewActions(p),
      ),
      transitionsBuilder: (_, a, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: a, curve: Curves.easeOutCubic),
        child: child,
      ),
    ));

    if (changed == true && mounted) _loadAlbumAssets();
  }

  PreviewItem _toPreviewItem(AssetEntity a) {
    final isVideo = a.type == AssetType.video;
    return PreviewItem(
      id: a.id,
      isVideo: isVideo,
      imageBuilder: () => AssetEntityImageProvider(
        a,
        isOriginal: false,
        thumbnailSize: const ThumbnailSize(2048, 2048),
        thumbnailFormat: ThumbnailFormat.jpeg,
      ),
      heroTag: 'photo_${a.id}', // grid Hero tag tho match avvali
      title: a.title,
      detailsLoader: () => _loadInfo(a),
      onPlay: (ctx) async {
        final f = await a.originFile;
        if (f == null || !ctx.mounted) return;
        Navigator.push(
          ctx,
          MaterialPageRoute(builder: (_) => VideoPlayerScreen(file: f, title: a.title)),
        );
      },
      data: a,
    );
  }

  List<PreviewAction> _previewActions(AppPalette p) {
    return [
      // ── Dock ──
      PreviewAction(
        icon: Icons.ios_share_rounded,
        label: 'Share',
        color: p.accent,
        removesItem: false,
        run: (i) async {
          final f = await (i.data as AssetEntity).originFile;
          if (f == null) throw const PreviewCancelled();
          await Share.shareXFiles([XFile(f.path)]);
        },
      ),
      PreviewAction(
        icon: Icons.security_rounded,
        label: 'Vault',
        color: p.accent,
        run: (i) => _pvToVault(p, i.data as AssetEntity),
      ),
      PreviewAction(
        icon: Icons.delete_outline_rounded,
        label: 'Delete',
        color: Colors.redAccent,
        confirmTitle: 'డిలీట్ చేయాలా?',
        confirmMessage: 'ఈ ఐటెమ్ గ్యాలరీ నుండి డిలీట్ చేయబడుతుంది.',
        run: (i) => _pvDelete(i.data as AssetEntity),
      ),

      // ── More sheet ──
      PreviewAction(
        icon: Icons.copy_rounded,
        label: 'Copy to',
        color: const Color(0xFF7CE0B0),
        inDock: false,
        removesItem: false,
        run: (i) => _pvCopy(p, i.data as AssetEntity),
      ),
      PreviewAction(
        icon: Icons.drive_file_move_rounded,
        label: 'Move to',
        color: const Color(0xFFB892FF),
        inDock: false,
        run: (i) => _pvMove(p, i.data as AssetEntity),
      ),
      PreviewAction(
        icon: Icons.crop_rotate_rounded,
        label: 'Crop/Rotate',
        color: const Color(0xFFFFC857),
        inDock: false,
        removesItem: false,
        run: (i) => _pvCropRotate(p, i.data as AssetEntity),
      ),
    ];
  }

  Future<void> _pvDelete(AssetEntity a) async {
    final res = await _busy(() => PhotoManager.editor.deleteWithIds([a.id]));
    if (res.isEmpty) throw const PreviewCancelled(); // user system dialog lo deny chesadu
  }

  Future<void> _pvToVault(AppPalette p, AssetEntity a) async {
    final target = await _showVaultAlbumPicker(p, 'వాల్ట్ లోకి మార్చు (Vault)');
    if (target == null || !mounted) throw const PreviewCancelled();

    final ok = await _busy(() => VaultService().hideAsset(a, target));
    if (!ok) {
      _snack('Vault ki move avvaledu ❌');
      throw const PreviewCancelled();
    }
    final del = await _busy(() => PhotoManager.editor.deleteWithIds([a.id]));
    if (del.isEmpty) {
      _snack('Vault lo save ayindi, kani original delete avvaledu');
      throw const PreviewCancelled();
    }
    _snack('Moved to Vault 🔒');
  }

  Future<void> _pvCopy(AppPalette p, AssetEntity a) async {
    final target = await _showLocalAlbumPicker(p, 'Copy to Album');
    if (target == null || !mounted) throw const PreviewCancelled();

    final n = await _busy(() => PhotoManager.editor.copyAssetToPath(asset: a, pathEntity: target));
    if (n == null) {
      _snack('Copy failed ❌');
      throw const PreviewCancelled();
    }
    _snack('Copied to ${target.name} 📄');
  }

  Future<void> _pvMove(AppPalette p, AssetEntity a) async {
    final target = await _showLocalAlbumPicker(p, 'Move to Album');
    if (target == null || !mounted) throw const PreviewCancelled();

    final n = await _busy(() => PhotoManager.editor.copyAssetToPath(asset: a, pathEntity: target));
    if (n == null) {
      _snack('Move failed ❌');
      throw const PreviewCancelled();
    }
    final del = await _busy(() => PhotoManager.editor.deleteWithIds([a.id]));
    if (del.isEmpty) {
      _snack('Copied to ${target.name}, kani original delete avvaledu');
      throw const PreviewCancelled();
    }
    _snack('Moved to ${target.name} 🚀');
  }

  /// Original overwrite cheyyadu: edited version new copy ga gallery lo save avtundi.
  Future<void> _pvCropRotate(AppPalette p, AssetEntity a) async {
    if (a.type == AssetType.video) {
      _snack('Videos ki crop ledu');
      throw const PreviewCancelled();
    }
    final f = await a.originFile;
    if (f == null) throw const PreviewCancelled();

    final cropped = await ImageCropper().cropImage(
      sourcePath: f.path,
      compressFormat: ImageCompressFormat.jpg,
      compressQuality: 95,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop & Rotate',
          toolbarColor: const Color(0xFF101116),
          toolbarWidgetColor: Colors.white,
          backgroundColor: Colors.black,
          activeControlsWidgetColor: p.accent,
          initAspectRatio: CropAspectRatioPreset.original,
          lockAspectRatio: false,
        ),
        IOSUiSettings(title: 'Crop & Rotate'),
      ],
    );
    if (cropped == null) throw const PreviewCancelled();

    await PhotoManager.editor.saveImageWithPath(
      cropped.path,
      title: 'edit_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    _snack('Saved as a new copy ✂️');
  }

  // ── INFO (EXIF) ──
  String _fmtSize(int b) {
    if (b <= 0) return '-';
    const u = ['B', 'KB', 'MB', 'GB'];
    var v = b.toDouble(), i = 0;
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${u[i]}';
  }

  String _tag(Map<String, IfdTag> t, String k) {
    final v = t[k]?.printable.trim();
    if (v == null || v.isEmpty || v == '0') return '';
    return v;
  }

  Future<Map<String, String>> _loadInfo(AssetEntity a) async {
    final isVideo = a.type == AssetType.video;
    final fmt = DateFormat('EEE, d MMM yyyy • h:mm a');
    final out = <String, String>{
      'Name': a.title ?? '-',
      'Album': widget.albumName,
      'Type': isVideo ? 'Video' : 'Photo',
      'Date': fmt.format(a.createDateTime),
      'Modified': fmt.format(a.modifiedDateTime),
      'Resolution': '${a.width} × ${a.height}',
      if (isVideo) 'Duration': '${a.videoDuration.inSeconds} sec',
    };

    try {
      final f = await a.originFile;
      if (f != null && await f.exists()) {
        out['Size'] = _fmtSize(await f.length());

        if (!isVideo) {
          final tags = await readExifFromBytes(await f.readAsBytes());
          final exif = <String, String>{
            'Camera': [_tag(tags, 'Image Make'), _tag(tags, 'Image Model')].where((s) => s.isNotEmpty).join(' '),
            'Lens': _tag(tags, 'EXIF LensModel'),
            'Exposure': _tag(tags, 'EXIF ExposureTime'),
            'Aperture': _tag(tags, 'EXIF FNumber'),
            'ISO': _tag(tags, 'EXIF ISOSpeedRatings'),
            'Focal Length': _tag(tags, 'EXIF FocalLength'),
            'Flash': _tag(tags, 'EXIF Flash'),
          };
          exif.forEach((k, v) { if (v.isNotEmpty) out[k] = v; });
        }
        out['Path'] = f.path;
      }
    } catch (_) {}

    return out;
  }

  // ════════════════════════════════════════════════════════════════
  //  BUILD
  // ════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final p = context.watch<ThemeProvider>().p;
    final selecting = _selected.isNotEmpty;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(statusBarColor: Colors.transparent, statusBarIconBrightness: p.bg == const Color(0xFF090A0F) ? Brightness.light : Brightness.dark),
      child: PopScope(
        canPop: !selecting,
        onPopInvokedWithResult: (didPop, _) { if (!didPop && selecting) setState(_selected.clear); },
        child: Scaffold(
          backgroundColor: p.bg,
          body: Stack(
            children: [
              Positioned.fill(
                child: _loading
                    ? Center(child: CircularProgressIndicator(color: p.accent))
                    : GridView.builder(
                        physics: const BouncingScrollPhysics(),
                        padding: EdgeInsets.only(top: mq.padding.top + 70, left: 4, right: 4, bottom: mq.padding.bottom + 120),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 3, mainAxisSpacing: 3),
                        itemCount: _items.length,
                        itemBuilder: (context, index) {
                          final asset = _items[index];
                          final isVideo = asset.type == AssetType.video;
                          final sel = _selected.contains(asset.id);

                          return GestureDetector(
                            onTap: () { if (selecting) { _toggle(asset); } else { _openPreview(index); } },
                            onLongPress: () { HapticFeedback.mediumImpact(); _toggle(asset); },
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Hero(
                                    tag: 'photo_${asset.id}', flightShuttleBuilder: _shuttle(AssetEntityImageProvider(asset, isOriginal: false)),
                                    child: Image(image: AssetEntityImageProvider(asset, isOriginal: false, thumbnailSize: const ThumbnailSize.square(300)), fit: BoxFit.cover, gaplessPlayback: true),
                                  ),
                                  if (isVideo) const Center(child: Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 28, shadows: [Shadow(color: Colors.black54, blurRadius: 4)])),
                                  AnimatedContainer(duration: const Duration(milliseconds: 180), color: sel ? p.accent.withValues(alpha: 0.22) : Colors.transparent),
                                  if (selecting) Positioned(top: 6, left: 6, child: _Check(on: sel, p: p)),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),

              // ── TOP GLASS BAR ──
              Positioned(
                top: 0, left: 0, right: 0,
                child: _Glass(
                  p: p, radius: 0, blur: 28, border: Border(bottom: BorderSide(color: p.border)),
                  child: Padding(
                    padding: EdgeInsets.only(top: mq.padding.top),
                    child: SizedBox(
                      height: 56,
                      child: selecting
                        ? Row(
                            children: [
                              IconButton(icon: Icon(Icons.close_rounded, color: p.text), onPressed: () => setState(_selected.clear)),
                              Expanded(child: Text('${_selected.length} Selected', style: TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.bold))),
                              IconButton(icon: Icon(Icons.select_all_rounded, color: p.text), onPressed: () => setState(() => _selected.length == _items.length ? _selected.clear() : _selected.addAll(_items.map((e) => e.id)))),
                            ],
                          )
                        : Row(
                            children: [
                              const SizedBox(width: 8),
                              IconButton(icon: Icon(Icons.arrow_back_ios_new_rounded, color: p.text, size: 20), onPressed: () => Navigator.pop(context)),
                              Expanded(child: Text(widget.albumName, style: TextStyle(color: p.text, fontSize: 20, fontWeight: FontWeight.bold))),
                              IconButton(tooltip: 'Info', icon: Icon(Icons.info_outline_rounded, color: p.accent), onPressed: () => _showAlbumStats(context, p)),
                              const SizedBox(width: 8),
                            ],
                          ),
                    ),
                  ),
                ),
              ),

              // ── BOTTOM DOCK ACTIONS ──
              Positioned(
                left: 12, right: 12, bottom: mq.padding.bottom + 12,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280), switchInCurve: Curves.easeOutCubic,
                  transitionBuilder: (c, a) => FadeTransition(opacity: a, child: SlideTransition(position: Tween(begin: const Offset(0, 0.8), end: Offset.zero).animate(a), child: c)),
                  child: selecting
                      ? DecoratedBox(
                          key: const ValueKey('dock'),
                          decoration: BoxDecoration(borderRadius: BorderRadius.circular(30), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 28, offset: const Offset(0, 8))]),
                          child: _Glass(
                            p: p, radius: 30, blur: 30,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: [
                                  _DockBtn(icon: Icons.ios_share_rounded, label: 'Share', color: p.accent, p: p, onTap: _shareSelected),
                                  _DockBtn(icon: Icons.copy_rounded, label: 'Copy', color: p.accent, p: p, onTap: () => _copyLocalSelected(p)),
                                  _DockBtn(icon: Icons.drive_file_move_rounded, label: 'Move', color: p.accent, p: p, onTap: () => _moveLocalSelected(p)),
                                  _DockBtn(icon: Icons.security_rounded, label: 'Vault', color: p.accent, p: p, onTap: () => _moveToVaultSelected(p)),
                                  _DockBtn(icon: Icons.delete_outline_rounded, label: 'Delete', color: Colors.redAccent, p: p, onTap: () => _deleteSelected(p)),
                                ],
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
      ),
    );
  }
}