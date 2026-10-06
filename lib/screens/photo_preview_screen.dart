import 'dart:io';
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
    if (mounted) Navigator.pop(context, true); // gallery reloads
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _chrome
          ? AppBar(
              backgroundColor: Colors.black45,
              elevation: 0,
              iconTheme: const IconThemeData(color: Colors.white),
              title: Text('${_index + 1} / ${widget.items.length}',
                  style: const TextStyle(color: Colors.white, fontSize: 16)),
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
              // cap decode size so 50MP photos don't OOM
              imageProvider: ResizeImage.resizeIfNeeded(2400, null, FileImage(File(item.encryptedPath))),
              heroAttributes: PhotoViewHeroAttributes(tag: 'vault_${item.id}'),
              minScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.covered * 3,
            );
          },
        ),
      ),
      bottomNavigationBar: _chrome
          ? BottomAppBar(
              color: Colors.black54,
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                if (widget.trash) ...[
                  IconButton(
                    icon: const Icon(Icons.restore, color: Colors.white),
                    onPressed: () => _act(() => DatabaseHelper.instance.setDeleted([_cur.id!], false))),
                  IconButton(
                    icon: const Icon(Icons.delete_forever, color: Colors.white),
                    onPressed: () => _act(() => VaultService().deleteForever([_cur]))),
                ] else ...[
                  IconButton(
                    icon: const Icon(Icons.output, color: Colors.white),
                    onPressed: () => _act(() => VaultService().exportToGallery([_cur]))),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.white),
                    onPressed: () => _act(() => DatabaseHelper.instance.setDeleted([_cur.id!], true))),
                ],
              ]),
            )
          : null,
    );
  }
}