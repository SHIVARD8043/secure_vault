import 'dart:io';
import 'dart:ui' as ui;
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:share_plus/share_plus.dart';
import 'package:provider/provider.dart';
import '../core/theme_provider.dart';
import '../core/vault_service.dart';
import '../db/database_helper.dart';
import '../db/vault_item_model.dart';
import 'video_player_screen.dart';

// ════════════════════════════════════════════════════════════════════
//  GLASS WIDGET & SHARED BUTTON
// ════════════════════════════════════════════════════════════════════
class _Glass extends StatelessWidget {
  const _Glass({
    super.key, this.p, required this.child, this.radius = 24, this.blur = 25, this.color, this.border,
  });
  
  final AppPalette? p; 
  final Widget child;
  final double radius, blur;
  final Color? color;
  final BoxBorder? border;

  @override
  Widget build(BuildContext context) {
    final br = radius > 0 ? BorderRadius.circular(radius) : null;
    return ClipRRect(
      borderRadius: br ?? BorderRadius.zero,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color ?? (p != null ? p!.bar : Colors.black.withOpacity(0.45)), 
            borderRadius: br, 
            border: border ?? (radius > 0 && p != null ? Border.all(color: p!.border) : null)
          ),
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
Future<T> _withProgress<T>(BuildContext context, Future<T> Function() job) async {
  showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
  try { return await job(); } finally { if (context.mounted) Navigator.of(context).pop(); }
}

Future<String?> _pickAlbum(BuildContext context, String title, AppPalette p) async {
  final albums = (await DatabaseHelper.instance.fetchAlbums()).map((e) => e['albumName'] as String).toList();
  if (!context.mounted) return null;
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: p.surface, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
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
      ..['isDeleted'] = 0 
      ..['encryptedPath'] = newPath;
    await db.insert('vault_items', row);
    return true;
  } catch (_) {
    try { await File(newPath).delete(); } catch (_) {}
    return false;
  }
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
  out['Status'] = 'In Recycle Bin 🗑️';
  if (await f.exists()) {
    final st = await f.stat();
    out['Modified'] = DateFormat('d MMM yyyy • h:mm a').format(st.modified);
    out['Size'] = _fmtSize(st.size);
    final ext = out['Name']!.contains('.') ? out['Name']!.split('.').last.toUpperCase() : '-';
    out['Type'] = ext;
    try {
      final buf = await ui.ImmutableBuffer.fromUint8List(await f.readAsBytes());
      final d = await ui.ImageDescriptor.encoded(buf);
      out['Resolution'] = '${d.width} × ${d.height}  (${((d.width * d.height) / 1e6).toStringAsFixed(1)} MP)';
      d.dispose(); buf.dispose();
    } catch (_) {}
  } else {
    out['Size'] = 'File missing';
  }
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
                ? SizedBox(height: 160, child: Center(child: CircularProgressIndicator(color: p.accent)))
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
//  BIN SCREEN (Grid)
// ════════════════════════════════════════════════════════════════════
class BinScreen extends StatefulWidget {
  const BinScreen({super.key});
  @override
  State<BinScreen> createState() => _BinScreenState();
}

class _BinScreenState extends State<BinScreen> {
  List<VaultItem> _items = [];
  final Set<int> _selected = {};
  bool _loading = true;
  
  int _sortType = 0; // 0: Created Date, 1: Modified Date, 2: Size
  String? _filterType; // null = all, 'video' = only videos, 'image' = only photos

  @override
  void initState() {
    super.initState();
    _loadBinItems();
  }

  Future<void> _loadBinItems() async {
    final allItems = await DatabaseHelper.instance.fetchAll();
    var binItems = allItems.where((i) => i.isDeleted == 1).toList();

    // 👈 6. Filtering Logic
    if (_filterType != null) {
      binItems = binItems.where((i) => i.type == _filterType).toList();
    }

    // 👈 5. Sorting Logic
    binItems.sort((a, b) {
      if (_sortType == 0) {
        final dA = DateTime.tryParse(a.addedDate ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        final dB = DateTime.tryParse(b.addedDate ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        return dB.compareTo(dA);
      } else if (_sortType == 1) {
        final fA = File(a.encryptedPath);
        final fB = File(b.encryptedPath);
        final dA = fA.existsSync() ? fA.statSync().modified : DateTime.fromMillisecondsSinceEpoch(0);
        final dB = fB.existsSync() ? fB.statSync().modified : DateTime.fromMillisecondsSinceEpoch(0);
        return dB.compareTo(dA);
      } else {
        final fA = File(a.encryptedPath);
        final fB = File(b.encryptedPath);
        final sA = fA.existsSync() ? fA.statSync().size : 0;
        final sB = fB.existsSync() ? fB.statSync().size : 0;
        return sB.compareTo(sA);
      }
    });

    if (mounted) {
      setState(() {
        _items = binItems;
        _loading = false;
      });
    }
  }

  void _toggle(VaultItem a) => setState(() { _selected.contains(a.id) ? _selected.remove(a.id) : _selected.add(a.id!); });

  // 👈 3. Custom Progress Dialog for 1/100
  void _showProgressDialog(String title, int total, ValueNotifier<int> progress) {
    final p = context.read<ThemeProvider>().p;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: Dialog(
          backgroundColor: p.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 24),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: p.accent),
                const SizedBox(width: 24),
                ValueListenableBuilder<int>(
                  valueListenable: progress,
                  builder: (_, val, __) => Text(
                    '$title\n$val / $total',
                    style: TextStyle(color: p.text, fontSize: 16, fontWeight: FontWeight.w600, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _restoreSelected() async {
    final chosen = _items.where((i) => _selected.contains(i.id)).toList();
    if (chosen.isEmpty) return;

    final progress = ValueNotifier<int>(0);
    _showProgressDialog('Restoring...', chosen.length, progress);

    for (int i = 0; i < chosen.length; i++) {
      progress.value = i + 1;
      await DatabaseHelper.instance.setDeleted([chosen[i].id!], false);
    }

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${chosen.length} items restored! ♻️')));
      setState(() => _selected.clear());
      _loadBinItems();
    }
  }

  Future<void> _deleteForeverSelected() async {
    final chosen = _items.where((i) => _selected.contains(i.id)).toList();
    if (chosen.isEmpty) return;

    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final p = context.read<ThemeProvider>().p;
        return AlertDialog(
          backgroundColor: p.surface, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
          title: Text('Delete Permanently?', style: TextStyle(color: p.text, fontWeight: FontWeight.bold)), // 👈 2. English Text
          content: Text('These ${chosen.length} items will be lost forever. Are you sure?', style: TextStyle(color: p.sub)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: p.text))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold))),
          ],
        );
      },
    );

    if (confirm != true || !mounted) return;

    final progress = ValueNotifier<int>(0);
    _showProgressDialog('Deleting...', chosen.length, progress);

    for (int i = 0; i < chosen.length; i++) {
      progress.value = i + 1;
      await VaultService().deleteForever([chosen[i]]);
    }

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Items permanently deleted 🗑️')));
      setState(() => _selected.clear());
      _loadBinItems();
    }
  }

  Future<void> _emptyBin() async {
    if (_items.isEmpty) return;
    setState(() { _selected.clear(); _selected.addAll(_items.map((e) => e.id!)); });
    await _deleteForeverSelected();
  }

  Future<void> _copySelected(AppPalette p) async {
    final target = await _pickAlbum(context, 'Copy to', p);
    if (target == null || !mounted) return;
    final chosen = _items.where((i) => _selected.contains(i.id)).toList();

    final progress = ValueNotifier<int>(0);
    _showProgressDialog('Copying...', chosen.length, progress);

    final db = await DatabaseHelper.instance.database;
    int successCount = 0;
    for (int i = 0; i < chosen.length; i++) {
      progress.value = i + 1;
      if (await _copyItem(db, chosen[i], target)) successCount++;
    }

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$successCount/${chosen.length} copied to $target 📄')));
      setState(() => _selected.clear());
      _loadBinItems();
    }
  }

  Future<void> _moveSelected(AppPalette p) async {
    final target = await _pickAlbum(context, 'Restore to Album', p);
    if (target == null || !mounted) return;
    final chosen = _items.where((i) => _selected.contains(i.id)).toList();
    
    final progress = ValueNotifier<int>(0);
    _showProgressDialog('Moving...', chosen.length, progress);

    final db = await DatabaseHelper.instance.database;
    int successCount = 0;
    for (int i = 0; i < chosen.length; i++) {
      progress.value = i + 1;
      await db.update('vault_items', {'albumName': target, 'isDeleted': 0}, where: 'id = ?', whereArgs: [chosen[i].id]);
      successCount++;
    }

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$successCount/${chosen.length} restored to $target 🚀')));
      setState(() => _selected.clear());
      _loadBinItems();
    }
  }

  // 👈 6. Tappable Details for Filtering in Bin
  Future<String?> _showBinStats(BuildContext context, AppPalette p) {
    return showModalBottomSheet<String>(
      context: context, backgroundColor: p.surface, isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => FutureBuilder<Map<String, String>>(
        future: () async {
          final allItems = await DatabaseHelper.instance.fetchAll();
          final baseItems = allItems.where((i) => i.isDeleted == 1).toList();
          
          int pCount = 0, vCount = 0, pSize = 0, vSize = 0;
          for (final item in baseItems) {
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
                      Text('Recycle Bin Info', style: TextStyle(color: p.text, fontSize: 20, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 20),
                      for (final e in m.entries)
                        GestureDetector(
                          onTap: () {
                            if (e.key == 'Videos') Navigator.pop(ctx, 'video');
                            else if (e.key == 'Photos') Navigator.pop(ctx, 'image');
                            else Navigator.pop(ctx, 'all');
                          },
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
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
                        ),
                    ]),
            ),
          );
        },
      ),
    );
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
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.delete_outline_rounded, size: 64, color: p.sub.withValues(alpha: 0.5)),
                              const SizedBox(height: 16),
                              Text('Bin is empty', style: TextStyle(color: p.sub, fontSize: 16)), // 👈 English Text
                            ],
                          ),
                        )
                      : GridView.builder(
                          physics: const BouncingScrollPhysics(),
                          padding: EdgeInsets.only(top: mq.padding.top + 70, left: 4, right: 4, bottom: 120),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 3, mainAxisSpacing: 3),
                          itemCount: _items.length,
                          itemBuilder: (context, index) {
                            final item = _items[index];
                            final sel = _selected.contains(item.id);
                            final isVideo = item.type == 'video';
                            final imgPath = (isVideo && item.thumbnailPath != null) ? item.thumbnailPath! : item.encryptedPath;
                            final file = File(imgPath);

                            // 👈 1. Glassy Cropped Edge Tile Design
                            final framed = DecoratedBox(
                              decoration: BoxDecoration(color: p.glass, borderRadius: BorderRadius.circular(11), border: Border.all(color: p.border)),
                              child: Padding(
                                padding: const EdgeInsets.all(1.5),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(9.5),
                                  child: Stack(fit: StackFit.expand, children: [
                                    Hero(
                                      tag: 'bin_${item.id}',
                                      child: file.existsSync() 
                                          ? Image.file(file, fit: BoxFit.cover, gaplessPlayback: true) 
                                          : Container(color: p.bg2, child: Icon(Icons.broken_image, color: p.sub)),
                                    ),
                                    
                                    if (isVideo)
                                      Positioned(
                                        right: 6, bottom: 6,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                          decoration: BoxDecoration(color: Colors.black.withOpacity(0.75), borderRadius: BorderRadius.circular(6)),
                                          child: const Row(mainAxisSize: MainAxisSize.min, children: [
                                            Icon(Icons.play_arrow_rounded, color: Colors.white, size: 14),
                                            SizedBox(width: 4),
                                            Text('VIDEO', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                                          ]),
                                        ),
                                      ),
                                      
                                    AnimatedContainer(duration: const Duration(milliseconds: 180), color: sel ? p.accent.withOpacity(0.22) : Colors.transparent),
                                    if (sel)
                                      Positioned(
                                        top: 7, left: 7,
                                        child: AnimatedContainer(
                                          duration: const Duration(milliseconds: 180),
                                          width: 24, height: 24,
                                          decoration: BoxDecoration(shape: BoxShape.circle, color: p.accent),
                                          child: const Icon(Icons.check_rounded, size: 16, color: Colors.white),
                                        ),
                                      ),
                                  ]),
                                ),
                              ),
                            );

                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () async {
                                if (selecting) {
                                  _toggle(item);
                                } else {
                                  if (isVideo) {
                                    await Navigator.push(context, MaterialPageRoute(builder: (_) => VideoPlayerScreen(file: File(item.encryptedPath), title: item.originalName)));
                                  } else {
                                    final imgItems = _items.where((e) => e.type != 'video').toList();
                                    final idx = imgItems.indexWhere((e) => e.id == item.id);
                                    if (idx != -1) {
                                      final changed = await Navigator.push(context, MaterialPageRoute(builder: (_) => BinPreviewScreen(items: imgItems, initialIndex: idx)));
                                      if (changed == true) _loadBinItems();
                                    }
                                  }
                                }
                              },
                              onLongPress: () { HapticFeedback.mediumImpact(); _toggle(item); },
                              child: AnimatedScale(
                                scale: sel ? 0.86 : 1, duration: const Duration(milliseconds: 200), curve: Curves.easeOutCubic,
                                child: framed,
                              ),
                            );
                          },
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
                        : Row(
                            children: [
                              const SizedBox(width: 8),
                              IconButton(icon: Icon(Icons.arrow_back_ios_new_rounded, color: p.text, size: 20), onPressed: () => Navigator.pop(context)),
                              Expanded(child: Text('Recycle Bin', style: TextStyle(color: p.text, fontSize: 20, fontWeight: FontWeight.bold))),
                              
                              // 👈 5. Sorting Options 
                              PopupMenuButton<int>(
                                icon: Icon(Icons.sort_rounded, color: p.text),
                                color: p.surface,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                initialValue: _sortType,
                                onSelected: (val) {
                                  if (val != _sortType) {
                                    setState(() => _sortType = val);
                                    _loadBinItems();
                                  }
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(value: 0, child: Text('Created Date', style: TextStyle(color: p.text))),
                                  PopupMenuItem(value: 1, child: Text('Modified Date', style: TextStyle(color: p.text))),
                                  PopupMenuItem(value: 2, child: Text('Size', style: TextStyle(color: p.text))),
                                ],
                              ),

                              // Filter Info Button
                              IconButton(
                                tooltip: 'Bin Info',
                                icon: Icon(_filterType != null ? Icons.filter_alt_rounded : Icons.info_outline_rounded, color: _filterType != null ? p.accent : p.text), 
                                onPressed: () async {
                                  final res = await _showBinStats(context, p);
                                  if (res != null) {
                                    setState(() => _filterType = res == 'all' ? null : res);
                                    _loadBinItems();
                                  }
                                }
                              ),

                              if (_items.isNotEmpty)
                                TextButton(onPressed: _emptyBin, child: const Text('Empty', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold))),
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
                      key: const ValueKey('bin_actions_bar'),
                      p: p, radius: 28, blur: 26,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _ActionBtn(icon: Icons.restore_rounded, label: 'Restore', color: p.accent, onTap: _restoreSelected),
                            _ActionBtn(icon: Icons.drive_file_move_rounded, label: 'Move', color: p.accent, onTap: () => _moveSelected(p)),
                            _ActionBtn(icon: Icons.copy_rounded, label: 'Copy', color: p.accent, onTap: () => _copySelected(p)),
                            _ActionBtn(icon: Icons.delete_forever_rounded, label: 'Delete', color: Colors.redAccent, onTap: _deleteForeverSelected),
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
//  BIN PREVIEW SCREEN
// ════════════════════════════════════════════════════════════════════
class BinPreviewScreen extends StatefulWidget {
  final List<VaultItem> items;
  final int initialIndex;
  const BinPreviewScreen({super.key, required this.items, required this.initialIndex});
  @override
  State<BinPreviewScreen> createState() => _BinPreviewScreenState();
}

class _BinPreviewScreenState extends State<BinPreviewScreen> {
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
          ListTile(leading: Icon(Icons.drive_file_move_rounded, color: p.accent), title: Text('Restore to Album (Move)', style: TextStyle(color: p.text)), onTap: () => Navigator.pop(context, 'move')),
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
      final target = await _pickAlbum(context, 'Restore to Album', p);
      if (target != null) {
        final db = await DatabaseHelper.instance.database;
        await _withProgress(context, () => db.update('vault_items', {'albumName': target, 'isDeleted': 0}, where: 'id = ?', whereArgs: [_cur.id]));
        if (mounted) Navigator.pop(context, true); 
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final p = context.watch<ThemeProvider>().p;

    return Scaffold(
      backgroundColor: p.bg, // 👈 4. Theme Based Background
      extendBodyBehindAppBar: true,
      extendBody: true, // required for bottom bar blur to work nicely over image
      body: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            onTap: () => setState(() => _chrome = !_chrome),
            child: Stack(
              fit: StackFit.expand,
              children: [
                PhotoViewGallery.builder(
                  pageController: _pc,
                  itemCount: widget.items.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  backgroundDecoration: BoxDecoration(color: p.bg), 
                  builder: (_, i) {
                    final item = widget.items[i];
                    final isVideo = item.type == 'video';
                    final imgPath = (isVideo && item.thumbnailPath != null) ? item.thumbnailPath! : item.encryptedPath;
                    
                    // 👈 4. Double Tap To Zoom Fix with FileImage
                    return PhotoViewGalleryPageOptions(
                      imageProvider: FileImage(File(imgPath)),
                      heroAttributes: PhotoViewHeroAttributes(tag: 'bin_${item.id}'),
                      minScale: PhotoViewComputedScale.contained,
                      maxScale: PhotoViewComputedScale.covered * 3,
                    );
                  },
                ),

                if (_cur.type == 'video')
                  Center(
                    child: GestureDetector(
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => VideoPlayerScreen(file: File(_cur.encryptedPath), title: _cur.originalName))),
                      child: const Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 80, shadows: [Shadow(color: Colors.black54, blurRadius: 10)]),
                    ),
                  ),
              ],
            ),
          ),

          // Top Theme Glass Bar
          Positioned(
            top: 0, left: 0, right: 0,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200), opacity: _chrome ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !_chrome,
                child: _Glass(
                  p: p, radius: 0, blur: 25, color: p.bar, 
                  border: Border(bottom: BorderSide(color: p.border)),
                  child: Padding(
                    padding: EdgeInsets.only(top: mq.padding.top),
                    child: SizedBox(
                      height: 56,
                      child: Row(
                        children: [
                          IconButton(icon: Icon(Icons.arrow_back_ios_new_rounded, color: p.text, size: 20), onPressed: () => Navigator.pop(context)),
                          Expanded(child: Text('${_index + 1} / ${widget.items.length}', style: TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.bold))),
                          IconButton(tooltip: 'Details', icon: Icon(Icons.info_outline_rounded, color: p.text), onPressed: () => _showMeta(context, p, _cur)),
                          IconButton(tooltip: 'More', icon: Icon(Icons.more_vert_rounded, color: p.text), onPressed: () => _showPreviewActions(p)),
                          const SizedBox(width: 4),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Bottom Theme Glass Bar
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200), opacity: _chrome ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !_chrome,
                child: _Glass(
                  p: p, radius: 0, blur: 25, color: p.bar,
                  border: Border(top: BorderSide(color: p.border)),
                  child: Padding(
                    padding: EdgeInsets.only(bottom: mq.padding.bottom, top: 12),
                    child: SizedBox(
                      height: 70,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _ActionBtn(icon: Icons.restore_rounded, label: 'Restore', color: p.accent, onTap: () => _act(() => DatabaseHelper.instance.setDeleted([_cur.id!], false))),
                          _ActionBtn(icon: Icons.delete_forever_rounded, label: 'Delete Forever', color: Colors.redAccent, onTap: () => _act(() => VaultService().deleteForever([_cur]))),
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