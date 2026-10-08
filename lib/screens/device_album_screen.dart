import 'dart:io';
import 'dart:ui' show ImageFilter, lerpDouble;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../core/theme_provider.dart';
import '../core/vault_service.dart';
import '../db/database_helper.dart';
import 'home_preview_screen.dart';
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
    final count = await widget.album.assetCountAsync;
    final assets = await widget.album.getAssetListRange(start: 0, end: count);
    if (mounted) {
      setState(() {
        _items = assets;
        _loading = false;
      });
    }
  }

  void _toggle(AssetEntity a) {
    setState(() {
      _selected.contains(a.id) ? _selected.remove(a.id) : _selected.add(a.id);
    });
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

  // ── ACTIONS ──
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

    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    final vault = VaultService();
    final idsToDelete = <String>[];
    int ok = 0;

    for (final a in chosen) {
      if (await vault.hideAsset(a, target)) {
        ok++;
        idsToDelete.add(a.id);
      }
    }
    if (idsToDelete.isNotEmpty) await PhotoManager.editor.deleteWithIds(idsToDelete);

    if (mounted) {
      Navigator.pop(context);
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

    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    int ok = 0;
    for (final a in chosen) {
      final newAsset = await PhotoManager.editor.copyAssetToPath(asset: a, pathEntity: target);
      if (newAsset != null) ok++;
    }
    
    if (mounted) {
      Navigator.pop(context);
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

    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    int ok = 0;
    final idsToDelete = <String>[];
    for (final a in chosen) {
      final newAsset = await PhotoManager.editor.copyAssetToPath(asset: a, pathEntity: target);
      if (newAsset != null) { ok++; idsToDelete.add(a.id); }
    }
    if (idsToDelete.isNotEmpty) await PhotoManager.editor.deleteWithIds(idsToDelete);

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$ok items moved to ${target.name} 🚀')));
      setState(() => _selected.clear());
      _loadAlbumAssets();
    }
  }

  Future<void> _openPreview(int idx) async {
    final asset = _items[idx];
    if (asset.type == AssetType.video) {
      final f = await asset.originFile;
      if (f != null && mounted) await Navigator.of(context).push(MaterialPageRoute(builder: (_) => VideoPlayerScreen(file: f, title: asset.title)));
    } else {
      final imgs = _items.where((e) => e.type != AssetType.video).toList();
      final start = imgs.indexWhere((e) => e.id == asset.id);
      await Navigator.of(context).push(PageRouteBuilder<void>(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 420),
        reverseTransitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (_, __, ___) => HomePreviewScreen(items: imgs, initial: start < 0 ? 0 : start, thumbPx: 400),
        transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: CurvedAnimation(parent: a, curve: Curves.easeOutCubic), child: child),
      ));
    }
  }

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