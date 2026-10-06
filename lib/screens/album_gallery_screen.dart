import 'dart:io';
import 'package:flutter/material.dart';
import '../core/vault_service.dart';
import '../db/database_helper.dart';
import '../db/vault_item_model.dart';
import '../db/vault_queries.dart';
import 'photo_preview_screen.dart';

class AlbumGalleryScreen extends StatefulWidget {
  final String? album;
  final bool trash;
  const AlbumGalleryScreen({super.key, this.album, this.trash = false});
  @override
  State<AlbumGalleryScreen> createState() => _AlbumGalleryScreenState();
}

class _AlbumGalleryScreenState extends State<AlbumGalleryScreen> {
  List<VaultItem> _items = [];
  final Set<int> _selected = {};
  bool get _selecting => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = DatabaseHelper.instance;
    final list = widget.trash ? await db.fetchTrash() : await db.fetchByAlbum(widget.album!);
    if (!mounted) return;
    setState(() {
      _items = list;
      _selected.removeWhere((id) => !list.any((e) => e.id == id));
    });
  }

  List<VaultItem> get _selectedItems => _items.where((e) => _selected.contains(e.id)).toList();
  List<int> get _ids => _selected.toList();

  void _toggle(VaultItem i) => setState(() {
        _selected.contains(i.id) ? _selected.remove(i.id) : _selected.add(i.id!);
      });

  Future<void> _afterAction() async {
    _selected.clear();
    await _load();
  }

  Future<void> _moveToAlbum() async {
    final albums = (await DatabaseHelper.instance.fetchAlbums()).map((e) => e['albumName'] as String).toList();
    if (!mounted) return;
    final ctrl = TextEditingController();
    final target = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move to album'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: ctrl, decoration: const InputDecoration(hintText: 'New album name')),
          const SizedBox(height: 12),
          Wrap(spacing: 6, children: [
            for (final a in albums) ActionChip(label: Text(a), onPressed: () => Navigator.pop(ctx, a)),
          ]),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim().isEmpty ? null : ctrl.text.trim()),
            child: const Text('Move')),
        ],
      ),
    );
    if (target == null) return;
    await DatabaseHelper.instance.moveToAlbum(_ids, target); // files stay put, only DB changes
    await _afterAction();
  }

  Future<void> _confirmDeleteForever() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${_selected.length} permanently?'),
        content: const Text('Recover cheyyadam kudaradu.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await VaultService().deleteForever(_selectedItems);
    await _afterAction();
  }

  Future<void> _open(int index) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => PhotoPreviewScreen(items: _items, initialIndex: index, trash: widget.trash)),
    );
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_selected.clear);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.grey[900],
          iconTheme: const IconThemeData(color: Colors.white),
          title: Text(
            _selecting ? '${_selected.length} selected' : (widget.trash ? 'Trash' : widget.album!),
            style: const TextStyle(color: Colors.white)),
          actions: [
            if (_selecting) ...[
              IconButton(
                icon: const Icon(Icons.select_all),
                onPressed: () => setState(() => _selected.length == _items.length
                    ? _selected.clear()
                    : _selected.addAll(_items.map((e) => e.id!))),
              ),
              if (!widget.trash) IconButton(icon: const Icon(Icons.drive_file_move_outline), onPressed: _moveToAlbum),
              IconButton(
                icon: const Icon(Icons.output), // export back to phone gallery
                tooltip: 'Export to gallery',
                onPressed: () async {
                  await VaultService().exportToGallery(_selectedItems);
                  await _afterAction();
                },
              ),
              if (widget.trash) ...[
                IconButton(
                  icon: const Icon(Icons.restore),
                  onPressed: () async {
                    await DatabaseHelper.instance.setDeleted(_ids, false);
                    await _afterAction();
                  }),
                IconButton(icon: const Icon(Icons.delete_forever), onPressed: _confirmDeleteForever),
              ] else
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await DatabaseHelper.instance.setDeleted(_ids, true);
                    await _afterAction();
                  }),
            ],
          ],
        ),
        body: _items.isEmpty
            ? const Center(child: Text('Empty', style: TextStyle(color: Colors.white54, fontSize: 18)))
            : GridView.builder(
                padding: const EdgeInsets.all(2),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3, crossAxisSpacing: 2, mainAxisSpacing: 2),
                itemCount: _items.length,
                itemBuilder: (_, index) {
                  final item = _items[index];
                  final selected = _selected.contains(item.id);
                  return GestureDetector(
                    onTap: () => _selecting ? _toggle(item) : _open(index),
                    onLongPress: () => _toggle(item),
                    child: Stack(fit: StackFit.expand, children: [
                      Hero(
                        tag: 'vault_${item.id}',
                        child: Image.file(
                          File(item.thumbnailPath ?? item.encryptedPath),
                          cacheWidth: 300, // decode small, keeps scrolling smooth
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) => const Icon(Icons.broken_image, color: Colors.white24),
                        ),
                      ),
                      if (selected)
                        Container(
                          color: Colors.blue.withValues(alpha: 0.4),
                          alignment: Alignment.bottomRight,
                          padding: const EdgeInsets.all(4),
                          child: const Icon(Icons.check_circle, color: Colors.white)),
                    ]),
                  );
                },
              ),
      ),
    );
  }
}