import 'dart:io';
import 'dart:ui'; // 👈 Frosted glass effect kosam idi tappakunda undali
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import '../core/vault_service.dart';
import '../db/database_helper.dart';
import '../db/vault_item_model.dart';
import '../db/vault_queries.dart';

class PhotoPreviewScreen extends StatefulWidget {
  final List<VaultItem> items;
  final int initialIndex;
  final bool trash;
  const PhotoPreviewScreen({super.key, required this.items, required this.initialIndex, this.trash = false});
  @override
  State<PhotoPreviewScreen> createState() => _PhotoPreviewScreenState();
}

class _PhotoPreviewScreenState extends State<PhotoPreviewScreen> {
  late final PageController _pc = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _chrome = true;

  VaultItem get _cur => widget.items[_index];

  Future<void> _act(Future<void> Function() fn) async {
    await fn();
    if (mounted) Navigator.pop(context, true); 
  }

  // ─── Premium Button Widget ───
  Widget _premiumButton({required IconData icon, required String label, required Color color, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 6),
          Text(
            label, 
            style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3)
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      extendBody: true, // 👈 Bottom bar venuka kuda photo velthundi (Premium look)
      
      appBar: _chrome
          ? PreferredSize(
              preferredSize: const Size.fromHeight(kToolbarHeight),
              child: ClipRRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                  child: AppBar(
                    backgroundColor: Colors.black.withOpacity(0.4), // Glass effect
                    elevation: 0,
                    iconTheme: const IconThemeData(color: Colors.white),
                    centerTitle: true,
                    title: Text(
                      '${_index + 1} / ${widget.items.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.5)
                    ),
                  ),
                ),
              ),
            )
          : null,
          
      body: GestureDetector(
        onTap: () => setState(() => _chrome = !_chrome),
        child: PhotoViewGallery.builder(
          pageController: _pc,
          itemCount: widget.items.length,
          onPageChanged: (i) => setState(() => _index = i),
          backgroundDecoration: const BoxDecoration(color: Colors.black),
          builder: (_, i) {
            final item = widget.items[i];
            return PhotoViewGalleryPageOptions(
              imageProvider: ResizeImage.resizeIfNeeded(2400, null, FileImage(File(item.encryptedPath))),
              heroAttributes: PhotoViewHeroAttributes(tag: 'vault_${item.id}'),
              minScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.covered * 3,
            );
          },
        ),
      ),
      
      bottomNavigationBar: _chrome
          ? ClipRRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                child: Container(
                  color: Colors.black.withOpacity(0.4), // Glass effect
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).padding.bottom + 12, 
                    top: 16
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly, 
                    children: [
                      if (widget.trash) ...[
                        _premiumButton(
                          icon: Icons.restore_rounded, 
                          label: 'Restore', 
                          color: Colors.blueAccent, 
                          onTap: () => _act(() => DatabaseHelper.instance.setDeleted([_cur.id!], false))
                        ),
                        _premiumButton(
                          icon: Icons.delete_forever_rounded, 
                          label: 'Delete', 
                          color: Colors.redAccent, 
                          onTap: () => _act(() => VaultService().deleteForever([_cur]))
                        ),
                      ] else ...[
                        _premiumButton(
                          icon: Icons.ios_share_rounded, 
                          label: 'Export', 
                          color: Colors.blueAccent, 
                          onTap: () => _act(() => VaultService().exportToGallery([_cur]))
                        ),
                        _premiumButton(
                          icon: Icons.delete_outline_rounded, 
                          label: 'Trash', 
                          color: Colors.redAccent, 
                          onTap: () => _act(() => DatabaseHelper.instance.setDeleted([_cur.id!], true))
                        ),
                      ],
                    ]
                  ),
                ),
              ),
            )
          : null,
    );
  }
}