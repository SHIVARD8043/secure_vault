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
import '../core/vault_service.dart';
import '../db/database_helper.dart';
import '../db/vault_item_model.dart';
import '../db/vault_queries.dart';

// ════════════════════════════════════════════════════════════════════
//  PALETTE & GLASS WIDGET
// ════════════════════════════════════════════════════════════════════
class _P {
  const _P({
    required this.bg, required this.bg2, required this.text, required this.sub,
    required this.glass, required this.border, required this.bar, required this.accent, required this.surface,
  });
  final Color bg, bg2, text, sub, glass, border, bar, accent, surface;

  static const dark = _P(
    bg: Color(0xFF090A0F), bg2: Color(0xFF14161F), text: Color(0xFFF4F5FA), sub: Color(0xFF9AA1B5),
    glass: Color(0x14FFFFFF), border: Color(0x26FFFFFF), bar: Color(0x990A0B10), accent: Color(0xFF7C9CFF), surface: Color(0xFF1B1E2A),
  );
}

class _Glass extends StatelessWidget {
  const _Glass({
    super.key, required this.p, required this.child, this.radius = 24, this.blur = 22, this.border,
  });
  final _P p;
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

// ════════════════════════════════════════════════════════════════════
//  VAULT ACTIONS  (Share to / Copy to / Move to / Bin)  — NEW
//  Returns true if the vault changed (caller should reload).
// ════════════════════════════════════════════════════════════════════
enum _VAction { share, copy, move, bin }

Future<bool> _runVaultAction(BuildContext context, List<VaultItem> items, {String? currentAlbum}) async {
  if (items.isEmpty) return false;
  const p = _P.dark;

  final action = await showDialog<_VAction>(
    context: context,
    builder: (ctx) {
      Widget tile(IconData i, String t, _VAction a, {Color? color}) => ListTile(
            leading: Icon(i, color: color ?? p.accent),
            title: Text(t, style: TextStyle(color: color ?? p.text, fontWeight: FontWeight.w600)),
            onTap: () => Navigator.pop(ctx, a),
          );
      return SimpleDialog(
        backgroundColor: p.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        title: Text('${items.length} selected',
            style: TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.w700)),
        children: [
          tile(Icons.ios_share_rounded, 'Share to', _VAction.share),
          tile(Icons.copy_rounded, 'Copy to', _VAction.copy),
          tile(Icons.drive_file_move_rounded, 'Move to', _VAction.move),
          tile(Icons.delete_outline_rounded, 'Bin', _VAction.bin, color: Colors.redAccent),
        ],
      );
    },
  );
  if (action == null || !context.mounted) return false;

  switch (action) {
    case _VAction.share:
      final files = [
        for (final i in items)
          if (File(i.encryptedPath).existsSync()) XFile(i.encryptedPath)
      ];
      if (files.isNotEmpty) await Share.shareXFiles(files); // newer share_plus: SharePlus.instance.share(ShareParams(files: files))
      return false;

    case _VAction.copy:
    case _VAction.move:
      final isMove = action == _VAction.move;
      final target = await _pickAlbum(context, isMove ? 'Move to' : 'Copy to', exclude: isMove ? currentAlbum : null);
      if (target == null || !context.mounted) return false;
      final ok = await _withProgress(context, () async {
        final db = await DatabaseHelper.instance.database;
        var n = 0;
        for (final it in items) {
          try {
            if (isMove) {
              await db.update('vault_items', {'albumName': target}, where: 'id = ?', whereArgs: [it.id]);
              n++;
            } else if (await _copyItem(db, it, target)) {
              n++;
            }
          } catch (_) {}
        }
        return n;
      });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('$ok/${items.length} ${isMove ? 'moved' : 'copied'} to $target')));
      }
      return ok > 0;

    case _VAction.bin:
      await _withProgress(context,
          () => DatabaseHelper.instance.setDeleted(items.map((e) => e.id!).toList(), true));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${items.length} moved to bin 🗑️')));
      }
      return true;
  }
}

/// Duplicates the file on disk + its DB row into another album.
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
    try {
      await File(newPath).delete();
    } catch (_) {}
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

Future<String?> _pickAlbum(BuildContext context, String title, {String? exclude}) async {
  const p = _P.dark;
  final albums = (await DatabaseHelper.instance.fetchAlbums())
      .map((e) => e['albumName'] as String)
      .where((a) => a != exclude)
      .toList();
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
          TextField(
            controller: ctrl,
            style: TextStyle(color: p.text),
            decoration: InputDecoration(hintText: 'New album name', hintStyle: TextStyle(color: p.sub)),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(
              child: Wrap(spacing: 6, runSpacing: 6, children: [
                for (final a in albums)
                  ActionChip(
                    backgroundColor: p.bg2,
                    side: BorderSide(color: p.border),
                    label: Text(a, style: TextStyle(color: p.text)),
                    onPressed: () => Navigator.pop(ctx, a),
                  ),
              ]),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(
          onPressed: () {
            final n = ctrl.text.trim();
            if (n.isNotEmpty) Navigator.pop(ctx, n);
          },
          child: Text('Create', style: TextStyle(color: p.accent, fontWeight: FontWeight.bold)),
        ),
      ],
    ),
  );
}

// ════════════════════════════════════════════════════════════════════
//  METADATA SHEET — NEW
// ════════════════════════════════════════════════════════════════════
DateTime? _dateOf(VaultItem item) {
  try {
    if (item.addedDate != null) return DateTime.tryParse(item.addedDate.toString());
  } catch (_) {}
  return null;
}

String _fmtSize(int b) {
  if (b <= 0) return '-';
  const u = ['B', 'KB', 'MB', 'GB'];
  var v = b.toDouble(), i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
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
      d.dispose();
      buf.dispose();
    } catch (_) {}
  } else {
    out['Size'] = 'File missing';
  }
  out['Path'] = item.encryptedPath;
  return out;
}

Future<void> _showMeta(BuildContext context, VaultItem item) {
  const p = _P.dark;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: p.surface,
    isScrollControlled: true,
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
                            Expanded(
                                child: SelectableText(e.value,
                                    style: TextStyle(color: p.text, fontSize: 14, fontWeight: FontWeight.w600))),
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
//  1. ALBUM VIEW SCREEN (Date Grouping & Multi-Select)
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
  final Set<int> _selected = {}; // Selected Item IDs
  bool _loading = true;
  final _P p = _P.dark;

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    final allItems = await DatabaseHelper.instance.fetchAll();
    final albumItems = allItems.where((i) => i.albumName == widget.albumName && i.isDeleted == 0).toList();

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
      
      try {
        // ఇందాక పెట్టిన lastModifiedSync() తీసేసి పాత కోడ్ పెట్టాం 
        if (item.addedDate != null) {
          date = DateTime.tryParse(item.addedDate.toString()) ?? DateTime.now();
        }
      } catch (_) {}

      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final yesterday = today.subtract(const Duration(days: 1));
      final itemDate = DateTime(date.year, date.month, date.day);

      if (itemDate == today) return "ఈరోజు (Today)";
      if (itemDate == yesterday) return "నిన్న (Yesterday)";
      if (date.year == now.year) return DateFormat('MMMM d').format(date);
      return DateFormat('MMMM yyyy').format(date);
    });
  }

  void _toggle(VaultItem a) => setState(() {
        _selected.contains(a.id) ? _selected.remove(a.id) : _selected.add(a.id!);
      });

  // ─── NEW: Share / Copy / Move / Bin dialog ───
  Future<void> _openActions() async {
    final chosen = _items.where((i) => _selected.contains(i.id)).toList();
    final changed = await _runVaultAction(context, chosen, currentAlbum: widget.albumName);
    if (changed && mounted) {
      setState(_selected.clear);
      _loadItems();
    }
  }

  // ─── MOVE TO ANOTHER ALBUM ───
  Future<void> _moveSelected() async {
    if (_selected.isEmpty) return;

    final albums = (await DatabaseHelper.instance.fetchAlbums())
        .map((e) => e['albumName'] as String)
        .where((a) => a != widget.albumName) // ఈ ఆల్బమ్ ని లిస్ట్ లోంచి తీసేస్తున్నాం
        .toList();

    final ctrl = TextEditingController();

    if (!mounted) return;
    final targetAlbum = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        title: Text('ఆల్బమ్ మార్చండి', style: TextStyle(color: p.text, fontWeight: FontWeight.bold)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: ctrl, style: TextStyle(color: p.text), decoration: InputDecoration(hintText: 'కొత్త ఆల్బమ్ పేరు', hintStyle: TextStyle(color: p.sub))),
          const SizedBox(height: 12),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final a in albums)
              ActionChip(
                backgroundColor: p.bg2, side: BorderSide(color: p.border),
                label: Text(a, style: TextStyle(color: p.text)),
                onPressed: () => Navigator.pop(ctx, a),
              ),
          ]),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim().isEmpty ? null : ctrl.text.trim()), child: Text('Move', style: TextStyle(color: p.accent, fontWeight: FontWeight.bold))),
        ],
      ),
    );

    if (targetAlbum == null || !mounted) return;
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));

    // డేటాబేస్ లో ఆల్బమ్ పేరు అప్‌డేట్ చేస్తున్నాం
    final db = await DatabaseHelper.instance.database;
    for (final id in _selected) {
      await db.update('vault_items', {'albumName': targetAlbum}, where: 'id = ?', whereArgs: [id]);
    }

    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${_selected.length} ఫోటోలు $targetAlbum కి మూవ్ అయ్యాయి 🚀')));
    _selected.clear();
    _loadItems();
  }

  // ─── TRASH SELECTED ───
  Future<void> _trashSelected() async {
    if (_selected.isEmpty) return;
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));

    await DatabaseHelper.instance.setDeleted(_selected.toList(), true);

    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${_selected.length} ఫోటోలు ట్రాష్ లోకి వెళ్ళాయి 🗑️')));
    _selected.clear();
    _loadItems();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final selecting = _selected.isNotEmpty;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(statusBarColor: Colors.transparent, statusBarIconBrightness: Brightness.light),
      child: Scaffold(
        backgroundColor: p.bg,
        body: Stack(
          children: [
            // Body (Date-wise CustomScrollView)
            Positioned.fill(
              child: _loading
                  ? Center(child: CircularProgressIndicator(color: p.accent))
                  : _items.isEmpty
                      ? Center(child: Text('ఈ ఆల్బమ్ లో ఫోటోలు లేవు', style: TextStyle(color: p.sub, fontSize: 16)))
                      : CustomScrollView(
                          physics: const BouncingScrollPhysics(),
                          slivers: [
                            SliverPadding(padding: EdgeInsets.only(top: mq.padding.top + 60)), // గ్లాస్ బార్ కిందకి స్క్రోల్ అవ్వడానికి ప్యాడింగ్
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
                                        return GestureDetector(
                                          onTap: () async {
                                            if (selecting) {
                                              _toggle(item);
                                            } else {
                                              final globalIndex = _items.indexOf(item);
                                              final changed = await Navigator.push(context, MaterialPageRoute(
                                                builder: (_) => PhotoPreviewScreen(items: _items, initialIndex: globalIndex, albumName: widget.albumName)
                                              ));
                                              if (changed == true) _loadItems();
                                            }
                                          },
                                          onLongPress: () => _toggle(item),
                                          child: Stack(fit: StackFit.expand, children: [
                                            Hero(
                                              tag: 'vault_${item.id}',
                                              child: Image.file(File(item.encryptedPath), fit: BoxFit.cover),
                                            ),
                                            if (sel)
                                              Container(
                                                color: p.accent.withValues(alpha: 0.4),
                                                alignment: Alignment.bottomRight,
                                                padding: const EdgeInsets.all(4),
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
                            const SliverPadding(padding: EdgeInsets.only(bottom: 40)),
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
                        // ─── Selection Mode Bar ───
                        ? Row(
                            children: [
                              IconButton(icon: Icon(Icons.close_rounded, color: p.text), onPressed: () => setState(() => _selected.clear())),
                              Expanded(child: Text('${_selected.length} Selected', style: TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.bold))),
                              IconButton(
                                icon: Icon(Icons.select_all_rounded, color: p.text),
                                onPressed: () => setState(() => _selected.length == _items.length ? _selected.clear() : _selected.addAll(_items.map((e) => e.id!))),
                              ),
                              // NEW: Share to / Copy to / Move to / Bin
                              IconButton(
                                tooltip: 'Share, copy, move, bin',
                                icon: Icon(Icons.more_vert_rounded, color: p.text),
                                onPressed: _openActions,
                              ),
                              IconButton(icon: const Icon(Icons.drive_file_move_rounded, color: Colors.blueAccent), onPressed: _moveSelected),
                              IconButton(icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent), onPressed: _trashSelected),
                              const SizedBox(width: 4),
                            ],
                          )
                        // ─── Normal Mode Bar ───
                        : Row(
                            children: [
                              const SizedBox(width: 8),
                              IconButton(icon: Icon(Icons.arrow_back_ios_new_rounded, color: p.text, size: 20), onPressed: () => Navigator.pop(context)),
                              Expanded(child: Text(widget.albumName, style: TextStyle(color: p.text, fontSize: 20, fontWeight: FontWeight.bold))),
                              Text('${_items.length} Photos', style: TextStyle(color: p.sub, fontSize: 14)),
                              const SizedBox(width: 16),
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

// ════════════════════════════════════════════════════════════════════
//  2. UPDATED PHOTO PREVIEW SCREEN (Glassmorphism)
// ════════════════════════════════════════════════════════════════════
class PhotoPreviewScreen extends StatefulWidget {
  final List<VaultItem> items;
  final int initialIndex;
  final bool trash;
  final String? albumName; // NEW: used to hide the current album in "Move to"
  const PhotoPreviewScreen({
    super.key,
    required this.items,
    required this.initialIndex,
    this.trash = false,
    this.albumName,
  });
  @override
  State<PhotoPreviewScreen> createState() => _PhotoPreviewScreenState();
}

class _PhotoPreviewScreenState extends State<PhotoPreviewScreen> {
  late final PageController _pc = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _chrome = true;
  final _P p = _P.dark;

  VaultItem get _cur => widget.items[_index];

  Future<void> _act(Future<void> Function() fn) async {
    await fn();
    if (mounted) Navigator.pop(context, true);
  }

  // NEW
  Future<void> _actions() async {
    final changed = await _runVaultAction(context, [_cur], currentAlbum: widget.albumName ?? _cur.albumName);
    if (changed && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Photo Viewer
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

          // Top Glass Bar
          Positioned(
            top: 0, left: 0, right: 0,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _chrome ? 1.0 : 0.0,
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
                          // NEW: metadata + actions
                          IconButton(
                            tooltip: 'Details',
                            icon: const Icon(Icons.info_outline_rounded, color: Colors.white),
                            onPressed: () => _showMeta(context, _cur),
                          ),
                          if (!widget.trash)
                            IconButton(
                              tooltip: 'Share, copy, move, bin',
                              icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
                              onPressed: _actions,
                            ),
                          const SizedBox(width: 4),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Bottom Glass Bar
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _chrome ? 1.0 : 0.0,
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
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(height: 6),
          Text(label, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}