import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

import '../core/vault_service.dart';
import '../db/database_helper.dart';
import '../db/vault_item_model.dart';
import 'video_player_screen.dart';

class PhotoPreviewScreen extends StatefulWidget {
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
  State<PhotoPreviewScreen> createState() => _PhotoPreviewScreenState();
}

class _PhotoPreviewScreenState extends State<PhotoPreviewScreen> {
  late final PageController _pc =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _chrome = true;

  VaultItem get _cur => widget.items[_index];

  Future<void> _act(Future<void> Function() fn) async {
    await fn();
    if (mounted) Navigator.pop(context, true);
  }

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

  Widget _premiumButton({
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

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final item = _cur;

    return Scaffold(
      backgroundColor: const Color(0xFF050609),
      extendBodyBehindAppBar: true,
      extendBody: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Subtle ambient background glow for a premium viewer feel.
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
              itemCount: widget.items.length,
              onPageChanged: (i) => setState(() => _index = i),
              backgroundDecoration:
                  const BoxDecoration(color: Colors.transparent),
              builder: (_, i) {
                final current = widget.items[i];
                final isVideo = current.type == 'video';
                final imagePath =
                    (isVideo && current.thumbnailPath != null)
                        ? current.thumbnailPath!
                        : current.encryptedPath;

                return PhotoViewGalleryPageOptions(
                  imageProvider: ResizeImage.resizeIfNeeded(
                    2400,
                    null,
                    FileImage(File(imagePath)),
                  ),
                  heroAttributes: PhotoViewHeroAttributes(
                    tag: widget.trash
                        ? 'bin_${current.id}'
                        : 'vault_${current.id}',
                  ),
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

          if (item.type == 'video')
            Center(
              child: GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => VideoPlayerScreen(
                      file: File(item.encryptedPath),
                      title: item.originalName,
                    ),
                  ),
                ),
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.42),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withOpacity(0.35)),
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

          // Floating top glass controls.
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
                          horizontal: 8,
                          vertical: 5,
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              tooltip: 'Back',
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(
                                Icons.arrow_back_rounded,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    widget.trash ? 'Recently Deleted' : 'Secure Viewer',
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
                                    '${_index + 1}  /  ${widget.items.length}',
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
                                horizontal: 10,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                item.type == 'video'
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

          // Floating bottom action dock.
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
                      children: widget.trash
                          ? [
                              _premiumButton(
                                icon: Icons.restore_rounded,
                                label: 'Restore',
                                color: const Color(0xFF65B7FF),
                                onTap: () => _act(
                                  () => DatabaseHelper.instance
                                      .setDeleted([_cur.id!], false),
                                ),
                              ),
                              _premiumButton(
                                icon: Icons.delete_forever_rounded,
                                label: 'Delete forever',
                                color: const Color(0xFFFF647C),
                                onTap: () => _act(
                                  () => VaultService().deleteForever([_cur]),
                                ),
                              ),
                            ]
                          : [
                              _premiumButton(
                                icon: Icons.ios_share_rounded,
                                label: 'Export',
                                color: const Color(0xFF65B7FF),
                                onTap: () => _act(
                                  () => VaultService().exportToGallery([_cur]),
                                ),
                              ),
                              _premiumButton(
                                icon: Icons.delete_outline_rounded,
                                label: 'Move to bin',
                                color: const Color(0xFFFF647C),
                                onTap: () => _act(
                                  () => DatabaseHelper.instance
                                      .setDeleted([_cur.id!], true),
                                ),
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
    );
  }
}
