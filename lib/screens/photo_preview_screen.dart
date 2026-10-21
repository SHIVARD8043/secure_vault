import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:image_cropper/image_cropper.dart';
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
  final File? file; // used to show file size in Info
  final Map<String, String> details; // extra rows for Info sheet
  final Future<Map<String, String>> Function()? detailsLoader; // rich async Info
  final void Function(BuildContext context)? onPlay;
  final Object? data; // original object (VaultItem, AssetEntity, ...)

  const PreviewItem({
    required this.id,
    required this.imageBuilder,
    required this.heroTag,
    this.isVideo = false,
    this.title,
    this.file,
    this.details = const {},
    this.detailsLoader,
    this.onPlay,
    this.data,
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
  final String? confirmTitle;
  final String? confirmMessage;

  const PreviewAction({
    required this.icon,
    required this.label,
    required this.run,
    this.color = const Color(0xFF65B7FF),
    this.inDock = true,
    this.removesItem = true,
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
    if (v.type == 'video') return; // videos ki crop ledu

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
    if (cropped == null) return;

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
  late final PageController _pc =
      PageController(initialPage: widget.initialIndex);
  late final List<PreviewItem> _items = List.of(widget.items);
  late int _index = widget.initialIndex.clamp(0, _items.length - 1);
  bool _chrome = true;
  bool _changed = false;
  Timer? _slideshow;

  PreviewItem get _cur => _items[_index];

  @override
  void dispose() {
    _slideshow?.cancel();
    _pc.dispose();
    super.dispose();
  }

  void _close() => Navigator.pop(context, _changed);

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
      setState(() {});
      return;
    }

    _stopSlideshow();
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
    });
  }

  // ── slideshow ──────────────────────────────────────────────

  void _toggleSlideshow() {
    if (_slideshow != null) {
      _stopSlideshow();
      return;
    }
    setState(() => _chrome = false);
    _slideshow = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted || _items.length < 2 || !_pc.hasClients) return;
      _pc.animateToPage(
        (_index + 1) % _items.length,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeInOutCubic,
      );
    });
  }

  void _stopSlideshow() {
    _slideshow?.cancel();
    _slideshow = null;
    if (mounted) setState(() {});
  }

  void _onTapViewer() {
    if (_slideshow != null) {
      _stopSlideshow();
      setState(() => _chrome = true);
      return;
    }
    setState(() => _chrome = !_chrome);
  }

  // ── sheets ─────────────────────────────────────────────────

  void _showMore() {
    final extra = widget.actions.where((a) => !a.inDock).toList();
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
                _sheetTile(
                  _slideshow != null
                      ? Icons.pause_circle_outline_rounded
                      : Icons.slideshow_rounded,
                  _slideshow != null ? 'Stop show' : 'Slideshow',
                  const Color(0xFFB892FF),
                  () {
                    Navigator.pop(ctx);
                    _toggleSlideshow();
                  },
                ),
                _sheetTile(Icons.copy_rounded, 'Copy name',
                    const Color(0xFF7CE0B0), () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: _cur.title ?? ''));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Name copied'),
                      duration: Duration(seconds: 1),
                    ),
                  );
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

  static const _blue = Color(0xFF65B7FF);

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
                maxHeight: MediaQuery.of(ctx).size.height * 0.7,
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
                    if (item.detailsLoader != null)
                      FutureBuilder<Map<String, String>>(
                        future: item.detailsLoader!(),
                        builder: (_, s) {
                          if (s.connectionState != ConnectionState.done) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 24),
                              child: Center(child: CircularProgressIndicator()),
                            );
                          }
                          if (!s.hasData) {
                            return _infoRow('Error', 'Unable to load details');
                          }
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final e in s.data!.entries)
                                _infoRow(e.key, e.value),
                            ],
                          );
                        },
                      )
                    else ...[
                      _infoRow('Name', item.title ?? '-'),
                      _infoRow('Position', '${_index + 1} of ${_items.length}'),
                      for (final e in item.details.entries)
                        _infoRow(e.key, e.value),
                      if (item.file != null)
                        FutureBuilder<int>(
                          future: item.file!.length(),
                          builder: (_, s) => _infoRow(
                            'Size',
                            s.hasData ? _fmtSize(s.data!) : '...',
                          ),
                        ),
                    ],
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
              width: 82,
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

  // ── shared widgets ─────────────────────────────────────────

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
              onTap: _onTapViewer,
              child: PhotoViewGallery.builder(
                pageController: _pc,
                itemCount: _items.length,
                onPageChanged: (i) => setState(() => _index = i),
                backgroundDecoration:
                    const BoxDecoration(color: Colors.transparent),
                builder: (_, i) {
                  final it = _items[i];
                  return PhotoViewGalleryPageOptions(
                    key: ValueKey(it.id),
                    imageProvider: ResizeImage.resizeIfNeeded(
                      2400,
                      null,
                      it.imageBuilder(),
                    ),
                    heroAttributes: PhotoViewHeroAttributes(tag: it.heroTag),
                    minScale: PhotoViewComputedScale.contained,
                    maxScale: PhotoViewComputedScale.covered * 3,
                    errorBuilder: (_, __, ___) => const Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white54,
                        size: 54,
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
                              horizontal: 8, vertical: 5),
                          child: Row(
                            children: [
                              IconButton(
                                tooltip: 'Back',
                                onPressed: _close,
                                icon: const Icon(Icons.arrow_back_rounded,
                                    color: Colors.white),
                              ),
                              const SizedBox(width: 4),
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
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 7),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(
                                  item.isVideo
                                      ? Icons.videocam_rounded
                                      : Icons.photo_rounded,
                                  color: Colors.white70,
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Bottom dock
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
                    child: _glass(
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