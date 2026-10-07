import 'dart:io';
import 'dart:ui' as ui;
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:share_plus/share_plus.dart';
import 'package:provider/provider.dart'; // NEW: Theme Provider
import '../core/theme_provider.dart';
import '../core/vault_service.dart';
import '../db/database_helper.dart';
import '../db/vault_item_model.dart';
import 'video_player_screen.dart'; // NEW: Video Player


// ════════════════════════════════════════════════════════════════════
//  GLASS WIDGET & SHARED BUTTON
// ════════════════════════════════════════════════════════════════════
class _Glass extends StatelessWidget {
  const _Glass({
    super.key, required this.p, required this.child, this.radius = 24, this.blur = 22, this.border,
  });
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

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionBtn({required this.icon, required this.label, required this.color, required this.onTap});

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
            Text(label, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold)),
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
    final rows = await db.query('vault_items', where: 'id = ?', whereArgs: [it.id]);
    if (rows.isEmpty) throw StateError('row missing');
    final row = Map<String, Object?>.from(rows.first as Map)
      ..remove('id')
      ..['albumName'] = album
      ..['encryptedPath'] = newPath;
    await db.insert('vault_items', row);
    return true;
  } catch (_) {
    try { await File(newPath).delete(); } catch (_) {}
    return false;
  }
}

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

Future<String?> _pickAlbum(BuildContext context, String title, AppPalette p, {String? exclude}) async {
  final albums = (await DatabaseHelper.instance.fetchAlbums()).map((e) => e['albumName'] as String).where((a) => a != exclude).toList();
  if (!context.mounted) return null;
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      title: Text(title, style: TextStyle(color: p.text, fontWeight: FontWeight.bold)),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: ctrl, style: TextStyle(color: p.text), decoration: InputDecoration(hintText: 'New album name', hintStyle: TextStyle(color: p.sub))),
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(
              child: Wrap(spacing: 6, runSpacing: 6, children: [
                for (final a in albums) ActionChip(backgroundColor: p.bg2, side: BorderSide(color: p.border), label: Text(a, style: TextStyle(color: p.text)), onPressed: () => Navigator.pop(ctx, a)),
              ]),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(onPressed: () { final n = ctrl.text.trim(); if (n.isNotEmpty) Navigator.pop(ctx, n); }, child: Text('Confirm', style: TextStyle(color: p.accent, fontWeight: FontWeight.bold))),
      ],
    ),
  );
}

DateTime? _dateOf(VaultItem item) {
  try { if (item.addedDate != null) return DateTime.tryParse(item.addedDate.toString()); } catch (_) {}
  return null;
}

String _fmtSize(int b) {
  if (b <= 0) return '-';
  const u = ['B', 'KB', 'MB', 'GB'];
  var v = b.toDouble(), i = 0;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${u[i]}';
}

Future<Map<String, String>> _loadMeta(VaultItem item) async {
  final f = File(item.encryptedPath);
  final out = <String, String>{};
  out['Name'] = item.encryptedPath.split(RegExp(r'[\\/]')).last;
  final added = _dateOf(item);
  out['Added'] = added == null ? '-' : DateFormat('EEE, d MMM yyyy • h:mm a').format(added);
  out['Album'] = item.albumName;
  if (await f.exists()) {
    final st = await f.stat();
    out['Modified'] = DateFormat('d MMM yyyy • h:mm a').format(st.modified);
    out['Size'] = _fmtSize(st.size);
    final ext = out['Name']!.contains('.') ? out['Name']!.split('.').last.toUpperCase() : '-';
    out['Type'] = ext;
    try {
      final buf = await ui.ImmutableBuffer.fromUint8List(await f.readAsBytes());
      final d = await ui.ImageDescriptor.encoded(buf);
      out['Resolution'] = '${d.width} × ${d.height}  (${(d.width * d.height / 1e6).toStringAsFixed(1)} MP)';
      d.dispose(); buf.dispose();
    } catch (_) {}
  } else {
    out['Size'] = 'File missing';
  }
  out['Path'] = item.encryptedPath;
  return out;
}

Future<void> _showMeta(BuildContext context, AppPalette p, VaultItem item) {
  return showModalBottomSheet<void>(
    context: context, backgroundColor: p.surface, isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    builder: (_) => FutureBuilder<Map<String, String>>(
      future: _loadMeta(item),
      builder: (ctx, snap) {
        final m = snap.data;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
            child: m == null
                ? const SizedBox(height: 160, child: Center(child: CircularProgressIndicator()))
                : SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('Details', style: TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 8),
                      for (final e in m.entries)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            SizedBox(width: 96, child: Text(e.key, style: TextStyle(color: p.sub, fontSize: 13))),
                            Expanded(child: SelectableText(e.value, style: TextStyle(color: p.text, fontSize: 14, fontWeight: FontWeight.w600))),
                          ]),
                        ),
                    ]),
                  ),
          ),
        );
      },
    ),
  );
}

// ════════════════════════════════════════════════════════════════════
//  1. ALBUM VIEW SCREEN (Vault Items Grid)
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

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    final allItems = await DatabaseHelper.instance.fetchAll();
    
    // ── ముఖ్యమైన మార్పు: డమ్మీ ఫోల్డర్లని (type: 'folder') హైడ్ చేస్తున్నాం ──
    final albumItems = allItems.where((i) => 
      i.albumName == widget.albumName && 
      i.isDeleted == 0 &&
      i.type != 'folder' 
    ).toList();

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
      DateTime date = DateTime.now();
      try { if (item.addedDate != null) date = DateTime.tryParse(item.addedDate.toString()) ?? DateTime.now(); } catch (_) {}
      final now = DateTime.now(), today = DateTime(now.year, now.month, now.day), yesterday = today.subtract(const Duration(days: 1));
      final itemDate = DateTime(date.year, date.month, date.day);
      if (itemDate == today) return "ఈరోజు (Today)";
      if (itemDate == yesterday) return "నిన్న (Yesterday)";
      if (date.year == now.year) return DateFormat('MMMM d').format(date);
      return DateFormat('MMMM yyyy').format(date);
    });
  }

  void _toggle(VaultItem a) => setState(() { _selected.contains(a.id) ? _selected.remove(a.id) : _selected.add(a.id!); });

  // ── BOTTOM BAR ACTIONS ──
  Future<void> _shareSelected() async {
    final chosen = _items.where((i) => _selected.contains(i.id)).toList();
    final files = [for (final i in chosen) if (File(i.encryptedPath).existsSync()) XFile(i.encryptedPath)];
    if (files.isNotEmpty) {
      await Share.shareXFiles(files);
      setState(() => _selected.clear());
    }
  }

  Future<void> _copySelected(AppPalette p) async {
    final target = await _pickAlbum(context, 'Copy to', p);
    if (target == null || !mounted) return;
    final chosen = _items.where((i) => _selected.contains(i.id)).toList();
    final ok = await _withProgress(context, () async {
      final db = await DatabaseHelper.instance.database;
      var n = 0;
      for (final it in chosen) { if (await _copyItem(db, it, target)) n++; }
      return n;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$ok/${chosen.length} copied to $target 📄')));
      setState(() => _selected.clear());
      _loadItems();
    }
  }

  Future<void> _moveSelected(AppPalette p) async {
    final target = await _pickAlbum(context, 'Move to', p, exclude: widget.albumName);
    if (target == null || !mounted) return;
    final chosen = _items.where((i) => _selected.contains(i.id)).toList();
    final ok = await _withProgress(context, () async {
      final db = await DatabaseHelper.instance.database;
      var n = 0;
      for (final it in chosen) {
        await db.update('vault_items', {'albumName': target}, where: 'id = ?', whereArgs: [it.id]);
        n++;
      }
      return n;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$ok/${chosen.length} moved to $target 🚀')));
      setState(() => _selected.clear());
      _loadItems();
    }
  }

  Future<void> _trashSelected() async {
    await _withProgress(context, () => DatabaseHelper.instance.setDeleted(_selected.toList(), true));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${_selected.length} items moved to bin 🗑️')));
      setState(() => _selected.clear());
      _loadItems();
    }
  }
  // ── ALBUM PROPERTIES (INFO) ──
  Future<void> _showAlbumStats(BuildContext context, AppPalette p) {
    return showModalBottomSheet<void>(
      context: context, backgroundColor: p.surface, isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => FutureBuilder<Map<String, String>>(
        future: () async {
          int pCount = 0, vCount = 0, pSize = 0, vSize = 0;
          for (final item in _items) {
            final f = File(item.encryptedPath);
            int size = 0;
            if (await f.exists()) size = (await f.stat()).size;
            
            if (item.type == 'video') {
              vCount++;
              vSize += size;
            } else {
              pCount++;
              pSize += size;
            }
          }
          return {
            'Photos': '$pCount items  •  ${_fmtSize(pSize)}',
            'Videos': '$vCount items  •  ${_fmtSize(vSize)}',
            'Total Size': _fmtSize(pSize + vSize),
          };
        }(),
        builder: (ctx, snap) {
          final m = snap.data;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
              child: m == null
                  ? SizedBox(height: 160, child: Center(child: CircularProgressIndicator(color: p.accent)))
                  : Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('${widget.albumName} Info', style: TextStyle(color: p.text, fontSize: 20, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 20),
                      for (final e in m.entries)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Row(children: [
                            Icon(
                              e.key == 'Photos' ? Icons.image_outlined : e.key == 'Videos' ? Icons.play_circle_outline : Icons.storage_rounded, 
                              color: p.accent, size: 24
                            ),
                            const SizedBox(width: 12),
                            SizedBox(width: 100, child: Text(e.key, style: TextStyle(color: p.sub, fontSize: 15, fontWeight: FontWeight.w600))),
                            Expanded(child: Text(e.value, style: TextStyle(color: p.text, fontSize: 16, fontWeight: FontWeight.w700), textAlign: TextAlign.right)),
                          ]),
                        ),
                    ]),
            ),
          );
        },
      ),
    );
  }
  // ── RESTORE TO ORIGINAL GALLERY ──
  Future<void> _restoreToGallery() async {
    final chosen = _items.where((i) => _selected.contains(i.id)).toList();
    if (chosen.isEmpty) return;

    // పొరపాటున నొక్కకుండా కన్ఫర్మేషన్ అడుగుతున్నాం
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final p = context.read<ThemeProvider>().p;
        return AlertDialog(
          backgroundColor: p.surface, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
          title: Text('Unhide Photos?', style: TextStyle(color: p.text, fontWeight: FontWeight.bold)),
          content: Text('ఈ ${chosen.length} ఐటెమ్స్ మళ్ళీ మీ ఫోన్ పబ్లిక్ గ్యాలరీలోకి వెళ్లిపోతాయి. కన్ఫర్మ్ చేయాలా?', style: TextStyle(color: p.sub)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: p.text))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Unhide', style: TextStyle(color: p.accent, fontWeight: FontWeight.bold))),
          ],
        );
      },
    );

    if (confirm != true || !mounted) return;

    // VaultService లోని ఎక్స్‌పోర్ట్ ఫంక్షన్ ని కాల్ చేస్తున్నాం 
    await _withProgress(context, () => VaultService().exportToGallery(chosen));
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${chosen.length} items restored to gallery 🔓')));
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
      value: const SystemUiOverlayStyle(statusBarColor: Colors.transparent, statusBarIconBrightness: Brightness.light),
      child: Scaffold(
        backgroundColor: p.bg,
        body: Stack(
          children: [
            Positioned.fill(
              child: _loading
                  ? Center(child: CircularProgressIndicator(color: p.accent))
                  : _items.isEmpty
                      ? Center(child: Text('ఆల్బమ్ ఖాళీగా ఉంది', style: TextStyle(color: p.sub, fontSize: 16)))
                      : CustomScrollView(
                          physics: const BouncingScrollPhysics(),
                          slivers: [
                            SliverPadding(padding: EdgeInsets.only(top: mq.padding.top + 60)), 
                            ..._groupedItems.entries.expand((entry) {
                              final dateHeader = entry.key;
                              final itemsInGroup = entry.value;

                              return [
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 8),
                                    child: Text(dateHeader, style: TextStyle(color: p.text, fontSize: 15, fontWeight: FontWeight.bold)),
                                  ),
                                ),
                                SliverPadding(
                                  padding: const EdgeInsets.symmetric(horizontal: 2),
                                  sliver: SliverGrid(
                                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: 3, crossAxisSpacing: 2, mainAxisSpacing: 2
                                    ),
                                    delegate: SliverChildBuilderDelegate(
                                      (context, index) {
                                        final item = itemsInGroup[index];
                                        final sel = _selected.contains(item.id);
                                        final isVideo = item.type == 'video';
                                        
                                        // ── వీడియో అయితే థంబ్‌నెయిల్, ఫోటో అయితే ఒరిజినల్ ఫైల్ తీసుకుంటున్నాం ──
                                        final imgPath = (isVideo && item.thumbnailPath != null) ? item.thumbnailPath! : item.encryptedPath;
                                        final file = File(imgPath);

                                        return GestureDetector(
                                          onTap: () async {
                                            if (selecting) {
                                              _toggle(item);
                                            } else {
                                              if (isVideo) {
                                                // వీడియోని సపరేట్ వీడియో ప్లేయర్ కి పంపుతున్నాం
                                                await Navigator.push(context, MaterialPageRoute(builder: (_) => VideoPlayerScreen(file: File(item.encryptedPath), title: item.originalName)));
                                              } else {
                                                // PhotoViewGallery లో వీడియోలు క్రాష్ అవుతాయి కాబట్టి వాటిని ఫిల్టర్ చేసి పంపుతున్నాం 
                                                final imgItems = _items.where((e) => e.type != 'video').toList();
                                                final idx = imgItems.indexWhere((e) => e.id == item.id);
                                                if (idx != -1) {
                                                  final changed = await Navigator.push(context, MaterialPageRoute(builder: (_) => PhotoPreviewScreen(items: imgItems, initialIndex: idx, albumName: widget.albumName)));
                                                  if (changed == true) _loadItems();
                                                }
                                              }
                                            }
                                          },
                                          onLongPress: () { HapticFeedback.mediumImpact(); _toggle(item); },
                                          child: Stack(fit: StackFit.expand, children: [
                                            Hero(
                                              tag: 'vault_${item.id}',
                                              child: file.existsSync()
                                                  ? Image.file(file, fit: BoxFit.cover)
                                                  : Container(color: p.bg2, child: Icon(Icons.broken_image, color: p.sub)),
                                            ),
                                            
                                            // వీడియో అయితే పైన ప్లే బటన్ కనపడాలి
                                            if (isVideo)
                                              const Center(child: Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 36, shadows: [Shadow(color: Colors.black54, blurRadius: 4)])),
                                              
                                            if (sel)
                                              Container(
                                                color: p.accent.withValues(alpha: 0.4), alignment: Alignment.bottomRight, padding: const EdgeInsets.all(4),
                                                child: const Icon(Icons.check_circle, color: Colors.white),
                                              ),
                                          ]),
                                        );
                                      },
                                      childCount: itemsInGroup.length,
                                    ),
                                  ),
                                ),
                              ];
                            }),
                            const SliverPadding(padding: EdgeInsets.only(bottom: 120)), 
                          ],
                        ),
            ),

            // Top Glass Bar
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
                              IconButton(icon: Icon(Icons.close_rounded, color: p.text), onPressed: () => setState(() => _selected.clear())),
                              Expanded(child: Text('${_selected.length} Selected', style: TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.bold))),
                              IconButton(icon: Icon(Icons.select_all_rounded, color: p.text), onPressed: () => setState(() => _selected.length == _items.length ? _selected.clear() : _selected.addAll(_items.map((e) => e.id!)))),
                              const SizedBox(width: 8),
                            ],
                          )
                        // ఈ కింది విధంగా మార్చు
                        : Row(
                            children: [
                              const SizedBox(width: 8),
                              IconButton(icon: Icon(Icons.arrow_back_ios_new_rounded, color: p.text, size: 20), onPressed: () => Navigator.pop(context)),
                              Expanded(child: Text(widget.albumName, style: TextStyle(color: p.text, fontSize: 20, fontWeight: FontWeight.bold))),
                              
                              // 👈 ఇక్కడ కొత్తగా Info బటన్ యాడ్ చేశాం 
                              IconButton(
                                tooltip: 'Album Info',
                                icon: Icon(Icons.info_outline_rounded, color: p.accent), 
                                onPressed: () => _showAlbumStats(context, p)
                              ),
                              const SizedBox(width: 8),
                            ],
                          ),
                  ),
                ),
              ),
            ),
            
            // Bottom Glass Actions Bar
            Positioned(
              left: 12, right: 12, bottom: mq.padding.bottom + 12,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                transitionBuilder: (c, a) => FadeTransition(opacity: a, child: SlideTransition(position: Tween(begin: const Offset(0, 0.6), end: Offset.zero).animate(a), child: c)),
                child: selecting 
                  ? _Glass(
                      key: const ValueKey('vault_actions_bar'),
                      p: p, radius: 28, blur: 26,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _ActionBtn(icon: Icons.ios_share_rounded, label: 'Share', color: p.accent, onTap: _shareSelected),
                            _ActionBtn(icon: Icons.output_rounded, label: 'Unhide', color: p.accent, onTap: _restoreToGallery),
                            _ActionBtn(icon: Icons.copy_rounded, label: 'Copy', color: p.accent, onTap: () => _copySelected(p)),
                            _ActionBtn(icon: Icons.drive_file_move_rounded, label: 'Move', color: p.accent, onTap: () => _moveSelected(p)),
                            _ActionBtn(icon: Icons.delete_outline_rounded, label: 'Bin', color: Colors.redAccent, onTap: _trashSelected),
                          ],
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

// ════════════════════════════════════════════════════════════════════
//  2. PHOTO PREVIEW SCREEN (Vault Image Viewer)
// ════════════════════════════════════════════════════════════════════
class PhotoPreviewScreen extends StatefulWidget {
  final List<VaultItem> items;
  final int initialIndex;
  final bool trash;
  final String? albumName; 
  const PhotoPreviewScreen({
    super.key, required this.items, required this.initialIndex, this.trash = false, this.albumName,
  });
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

  Future<void> _showPreviewActions(AppPalette p) async {
    final act = await showModalBottomSheet<String>(
      context: context, backgroundColor: p.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 12),
          ListTile(leading: Icon(Icons.ios_share_rounded, color: p.accent), title: Text('Share', style: TextStyle(color: p.text)), onTap: () => Navigator.pop(context, 'share')),
          ListTile(leading: Icon(Icons.copy_rounded, color: p.accent), title: Text('Copy to Album', style: TextStyle(color: p.text)), onTap: () => Navigator.pop(context, 'copy')),
          ListTile(leading: Icon(Icons.drive_file_move_rounded, color: p.accent), title: Text('Move to Album', style: TextStyle(color: p.text)), onTap: () => Navigator.pop(context, 'move')),
          const SizedBox(height: 12),
        ]),
      ),
    );

    if (act == 'share' && mounted) {
      if (File(_cur.encryptedPath).existsSync()) await Share.shareXFiles([XFile(_cur.encryptedPath)]);
    } else if (act == 'copy' && mounted) {
      final target = await _pickAlbum(context, 'Copy to', p);
      if (target != null) {
        await _withProgress(context, () => _copyItem(DatabaseHelper.instance.database, _cur, target));
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied to $target ✅')));
      }
    } else if (act == 'move' && mounted) {
      final target = await _pickAlbum(context, 'Move to', p, exclude: widget.albumName ?? _cur.albumName);
      if (target != null) {
        final db = await DatabaseHelper.instance.database;
        await _withProgress(context, () => db.update('vault_items', {'albumName': target}, where: 'id = ?', whereArgs: [_cur.id]));
        if (mounted) Navigator.pop(context, true); 
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final p = context.watch<ThemeProvider>().p;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
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

          // Top Bar
          Positioned(
            top: 0, left: 0, right: 0,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200), opacity: _chrome ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !_chrome,
                child: _Glass(
                  p: p, radius: 0, blur: 20, border: Border(bottom: BorderSide(color: p.border)),
                  child: Padding(
                    padding: EdgeInsets.only(top: mq.padding.top),
                    child: SizedBox(
                      height: 56,
                      child: Row(
                        children: [
                          IconButton(icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20), onPressed: () => Navigator.pop(context)),
                          Expanded(child: Text('${_index + 1} / ${widget.items.length}', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))),
                          IconButton(tooltip: 'Details', icon: const Icon(Icons.info_outline_rounded, color: Colors.white), onPressed: () => _showMeta(context, p, _cur)),
                          if (!widget.trash) IconButton(tooltip: 'More', icon: const Icon(Icons.more_vert_rounded, color: Colors.white), onPressed: () => _showPreviewActions(p)),
                          const SizedBox(width: 4),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Bottom Bar
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200), opacity: _chrome ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !_chrome,
                child: _Glass(
                  p: p, radius: 0, blur: 20, border: Border(top: BorderSide(color: p.border)),
                  child: Padding(
                    padding: EdgeInsets.only(bottom: mq.padding.bottom),
                    child: SizedBox(
                      height: 80,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: widget.trash ? [
                          _ActionBtn(icon: Icons.restore_rounded, label: 'Restore', color: p.accent, onTap: () => _act(() => DatabaseHelper.instance.setDeleted([_cur.id!], false))),
                          _ActionBtn(icon: Icons.delete_forever_rounded, label: 'Delete', color: Colors.redAccent, onTap: () => _act(() => VaultService().deleteForever([_cur]))),
                        ] : [
                          _ActionBtn(icon: Icons.output_rounded, label: 'Export', color: p.accent, onTap: () => _act(() => VaultService().exportToGallery([_cur]))),
                          _ActionBtn(icon: Icons.delete_outline_rounded, label: 'Trash', color: Colors.redAccent, onTap: () => _act(() => DatabaseHelper.instance.setDeleted([_cur.id!], true))),
                        ],
                      ),
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