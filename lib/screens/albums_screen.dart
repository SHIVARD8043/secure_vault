import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_selector/file_selector.dart';
import 'package:shared_preferences/shared_preferences.dart'; // Added for sorting
import 'package:sqflite/sqflite.dart';

import '../core/theme_provider.dart'; // Theme Provider
import '../core/backup_service.dart';
import '../core/vault_service.dart';
import '../db/database_helper.dart';
import '../db/vault_queries.dart';
import 'album_view_screen.dart';
import 'bin_screen.dart';
import 'duplicate_finder_screen.dart';

// ════════════════════════════════════════════════════════════════════
//  GLASS WIDGET & ACTION BUTTON (Using AppPalette)
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
//  ALBUMS (VAULT) SCREEN
// ════════════════════════════════════════════════════════════════════
class AlbumsScreen extends StatefulWidget {
  const AlbumsScreen({super.key});
  @override
  State<AlbumsScreen> createState() => _AlbumsScreenState();
}

class _AlbumsScreenState extends State<AlbumsScreen> {
  List<String> _albums = [];
  Map<String, int> _albumCounts = {};
  Map<String, String> _albumCovers = {}; // albumName -> thumbnail file path
  int _binCount = 0;
  bool _loading = true;
  String? _selectedAlbum;
  int _sortType = 0; // 0: A-Z, 1: Z-A, 2: Most items, 3: Fewest items, 4: Recently added
  bool _showAlbumCovers = true;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  List<String> get _visibleAlbums {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return _albums;
    return _albums.where((name) => name.toLowerCase().contains(query)).toList();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadPrefs().then((_) => _loadAlbums());
  }

  Future<void> _loadPrefs() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final s = sp.getInt('vault_album_sort');
      if (s != null && s >= 0 && s <= 4) _sortType = s;
      _showAlbumCovers = sp.getBool('vault_album_covers') ?? true;
    } catch (e) {
      debugPrint('Load prefs error: $e');
    }
  }

  // ─── ALBUM COVERS (latest item thumbnail per album) ───
  Future<Map<String, String>> _loadCovers() async {
    final covers = <String, String>{};
    try {
      final db = await DatabaseHelper.instance.database;
      final rows = await db.query(
        'vault_items',
        columns: ['albumName', 'thumbnailPath'],
        where: "isDeleted = 0 AND type != 'folder' AND thumbnailPath IS NOT NULL AND thumbnailPath != ''",
        orderBy: 'addedDate DESC',
      );
      for (final r in rows) {
        final album = r['albumName'] as String?;
        final thumb = r['thumbnailPath'] as String?;
        if (album == null || thumb == null) continue;
        covers.putIfAbsent(album, () => thumb);
      }
    } catch (e) {
      debugPrint('Cover load error: $e');
    }
    return covers;
  }

  Future<void> _loadAlbums() async {
    final allItems = await DatabaseHelper.instance.fetchAll();
    int bin = 0;
    Map<String, int> counts = {};
    Set<String> albumNames = {};

    for (final item in allItems) {
      if (item.isDeleted == 1) {
        bin++;
      } else {
        albumNames.add(item.albumName);
        if (item.type != 'folder') {
          counts[item.albumName] = (counts[item.albumName] ?? 0) + 1;
        }
      }
    }

    final dbAlbums = await DatabaseHelper.instance.fetchAlbums();
    albumNames.addAll(dbAlbums.map((e) => e['albumName'] as String));

    final covers = await _loadCovers();

    // Latest item date per album supports the Recently Added option.
    final latestDates = <String, String>{};
    try {
      final db = await DatabaseHelper.instance.database;
      final rows = await db.query(
        'vault_items',
        columns: ['albumName', 'addedDate'],
        where: 'isDeleted = 0',
        orderBy: 'addedDate DESC',
      );
      for (final row in rows) {
        final album = row['albumName'] as String?;
        final date = row['addedDate']?.toString();
        if (album != null && date != null) latestDates.putIfAbsent(album, () => date);
      }
    } catch (e) {
      debugPrint('Album date sorting error: $e');
    }

    final list = albumNames.toList();
    if (_sortType == 0) {
      list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    } else if (_sortType == 1) {
      list.sort((a, b) => b.toLowerCase().compareTo(a.toLowerCase()));
    } else if (_sortType == 2) {
      list.sort((a, b) => (counts[b] ?? 0).compareTo(counts[a] ?? 0));
    } else if (_sortType == 3) {
      list.sort((a, b) => (counts[a] ?? 0).compareTo(counts[b] ?? 0));
    } else if (_sortType == 4) {
      list.sort((a, b) => (latestDates[b] ?? '').compareTo(latestDates[a] ?? ''));
    }

    if (mounted) {
      setState(() {
        _binCount = bin;
        _albumCounts = counts;
        _albumCovers = covers;
        _albums = list;
        _loading = false;
      });
    }
  }

  // ─── ALBUM DISPLAY SETTINGS ───
  Future<void> _showAlbumSettings(AppPalette p) async {
    var selectedSort = _sortType;
    var showCovers = _showAlbumCovers;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, dialogSetState) => AlertDialog(
          backgroundColor: p.surface,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
            side: BorderSide(color: p.border),
          ),
          title: Row(
            children: [
              Icon(Icons.tune_rounded, color: p.accent),
              const SizedBox(width: 10),
              Expanded(child: Text('Album Settings',
                style: TextStyle(color: p.text, fontWeight: FontWeight.bold))),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: p.glass,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: p.border),
                  ),
                  child: SwitchListTile(
                    value: showCovers,
                    onChanged: (value) => dialogSetState(() => showCovers = value),
                    activeColor: p.accent,
                    secondary: Icon(
                      showCovers ? Icons.image_rounded : Icons.hide_image_rounded,
                      color: p.accent,
                    ),
                    title: Text('Album covers',
                      style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      showCovers ? 'Show photo thumbnails' : 'Show folder icons only',
                      style: TextStyle(color: p.sub, fontSize: 12)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
                const SizedBox(height: 22),
                Text('SORT ALBUMS BY', style: TextStyle(
                  color: p.sub, fontSize: 11, letterSpacing: 1.2,
                  fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                ...[
                  (0, 'Name (A–Z)', Icons.sort_by_alpha_rounded),
                  (1, 'Name (Z–A)', Icons.sort_by_alpha_rounded),
                  (2, 'Most items first', Icons.photo_library_rounded),
                  (3, 'Fewest items first', Icons.filter_list_rounded),
                  (4, 'Recently added', Icons.schedule_rounded),
                ].map((option) => RadioListTile<int>(
                  value: option.$1,
                  groupValue: selectedSort,
                  onChanged: (value) {
                    if (value != null) dialogSetState(() => selectedSort = value);
                  },
                  activeColor: p.accent,
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 2),
                  secondary: Icon(option.$3, color: p.sub, size: 20),
                  title: Text(option.$2, style: TextStyle(color: p.text, fontSize: 14)),
                )),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text('Cancel', style: TextStyle(color: p.sub)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: p.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () async {
                final sp = await SharedPreferences.getInstance();
                await sp.setBool('vault_album_covers', showCovers);
                await sp.setInt('vault_album_sort', selectedSort);
                if (!mounted) return;
                setState(() {
                  _showAlbumCovers = showCovers;
                  _sortType = selectedSort;
                });
                Navigator.pop(dialogContext);
                await _loadAlbums();
              },
              child: const Text('Apply', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  // ─── BACKUP (Center Dialog with Progress) ───
  Future<void> _backup({String? albumName}) async {
    final p = context.read<ThemeProvider>().p;
    
    final progressVal = ValueNotifier<double>(0.0);
    final statusText = ValueNotifier<String>('Preparing...');
    final dialogState = ValueNotifier<int>(0); // 0: Loading, 1: Success, 2: Error

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        content: ValueListenableBuilder<int>(
          valueListenable: dialogState,
          builder: (ctx, state, _) {
            if (state == 1) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_circle_rounded, color: Colors.green, size: 64),
                  const SizedBox(height: 16),
                  Text('Backup Finished! 🎉', style: TextStyle(color: p.text, fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(albumName != null ? 'Album "$albumName" saved to Downloads folder.' : 'Complete backup saved to Downloads folder.', style: TextStyle(color: p.sub, fontSize: 14), textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: p.accent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: const EdgeInsets.symmetric(vertical: 12)),
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('OK', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
                    ),
                  )
                ],
              );
            } 
            else if (state == 2) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 64),
                  const SizedBox(height: 16),
                  Text('Backup Failed ❌', style: TextStyle(color: p.text, fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ValueListenableBuilder<String>(
                    valueListenable: statusText,
                    builder: (ctx, txt, _) => Text(txt, style: TextStyle(color: p.sub, fontSize: 14), textAlign: TextAlign.center),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: const EdgeInsets.symmetric(vertical: 12)),
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
                    ),
                  )
                ],
              );
            }

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                ValueListenableBuilder<double>(
                  valueListenable: progressVal,
                  builder: (ctx, prog, _) => CircularProgressIndicator(
                    value: prog > 0 ? prog : null, 
                    color: p.accent, backgroundColor: p.border, strokeWidth: 5,
                  ),
                ),
                const SizedBox(height: 20),
                Text('Backing up...', style: TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                ValueListenableBuilder<String>(
                  valueListenable: statusText,
                  builder: (ctx, txt, _) => Text(txt, style: TextStyle(color: p.sub, fontSize: 14, fontWeight: FontWeight.w500), textAlign: TextAlign.center),
                ),
                const SizedBox(height: 10),
              ],
            );
          },
        ),
      ),
    );

    try {
      final tempZip = await BackupService().createBackup(
        albumName: albumName,
        onProgress: (done, total) {
          progressVal.value = done / total;
          statusText.value = '$done / $total files processed';
        },
      );
      
      statusText.value = 'Moving to Downloads...';
      progressVal.value = 0.0;
      
      final savedPath = await BackupService().exportToDownloads(tempZip);
      
      if (savedPath != null) {
        dialogState.value = 1;
        if (mounted) setState(() => _selectedAlbum = null);
      } else {
        statusText.value = 'Storage permission denied. Please allow in app settings.';
        dialogState.value = 2;
      }
    } catch (e) {
      statusText.value = e.toString();
      dialogState.value = 2;
    }
  }

  // ─── RESTORE (Center Dialog) ───
  Future<void> _restore() async {
    const XTypeGroup zipTypeGroup = XTypeGroup(label: 'Zip Files', extensions: ['zip']);
    final XFile? file = await openFile(acceptedTypeGroups: [zipTypeGroup]);

    if (file == null || !mounted) return;
    final path = file.path;
    final p = context.read<ThemeProvider>().p;

    final dialogState = ValueNotifier<int>(0); 
    final restoredCount = ValueNotifier<int>(0);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        content: ValueListenableBuilder<int>(
          valueListenable: dialogState,
          builder: (ctx, state, _) {
            if (state == 1) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.settings_backup_restore_rounded, color: Colors.green, size: 64),
                  const SizedBox(height: 16),
                  Text('Restore Finished!', style: TextStyle(color: p.text, fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text('${restoredCount.value} items restored successfully 🔄', style: TextStyle(color: p.sub, fontSize: 14), textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: p.accent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: const EdgeInsets.symmetric(vertical: 12)),
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('OK', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
                    ),
                  )
                ],
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                CircularProgressIndicator(color: p.accent, strokeWidth: 5),
                const SizedBox(height: 20),
                Text('Restoring data...', style: TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text('Please wait', style: TextStyle(color: p.sub, fontSize: 14)),
                const SizedBox(height: 10),
              ],
            );
          },
        ),
      ),
    );

    try {
      final n = await BackupService().restore(File(path));
      restoredCount.value = n;
      dialogState.value = 1;
      if (mounted) _loadAlbums();
    } catch (e) {
      if (mounted) Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Restore failed: $e ❌')));
    }
  }

  // ─── DELETE ALBUM ───
  Future<void> _deleteAlbum(String album) async {
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    final allItems = await DatabaseHelper.instance.fetchAll();
    final targetItems = allItems.where((i) => i.albumName == album && i.isDeleted == 0).toList();

    if (targetItems.isNotEmpty) {
      await DatabaseHelper.instance.setDeleted(targetItems.map((e) => e.id!).toList(), true);
    }
    if (!mounted) return;
    Navigator.pop(context);
    setState(() => _selectedAlbum = null);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Album "$album" moved to bin 🗑️')));
    _loadAlbums();
  }

  // ─── NEW ALBUM ───
  // ─── NEW ALBUM ───
Future<void> _createNewAlbum(AppPalette p) async {
  final ctrl = TextEditingController();

  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(26),
      ),
      title: Text(
        'New Album',
        style: TextStyle(
          color: p.text,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        style: TextStyle(color: p.text),
        decoration: InputDecoration(
          hintText: 'Album Name...',
          hintStyle: TextStyle(color: p.sub),
        ),
        onSubmitted: (value) {
          Navigator.pop(ctx, value.trim());
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: Text(
            'Create',
            style: TextStyle(
              color: p.accent,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    ),
  );
  
  if (!mounted || name == null || name.trim().isEmpty) {
    ctrl.dispose();
    return;
  }

  ctrl.dispose();

  try {
    final db = await DatabaseHelper.instance.database;

    // Save album independently of its photos/videos.
    await db.insert(
      'vault_albums',
      {
        'albumName': name.trim(),
        'createdDate': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    await _loadAlbums();
  } catch (e) {
    debugPrint('Album Creation Error: $e');
  }
}

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final p = context.watch<ThemeProvider>().p;
    final selecting = _selectedAlbum != null;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(statusBarColor: Colors.transparent, statusBarIconBrightness: Brightness.light),
      child: Scaffold(
        backgroundColor: p.bg,
        body: DecoratedBox(
          decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [p.bg, p.bg2])),
          child: Stack(
            children: [
              // ─── BODY (Grid) ───
              Positioned.fill(
                child: _loading
                    ? Center(child: CircularProgressIndicator(color: p.accent))
                    : (_albums.isEmpty && _binCount == 0)
                        ? Center(child: Text('Vault is empty 🔒', style: TextStyle(color: p.sub, fontSize: 18)))
                        : CustomScrollView(
                            physics: const BouncingScrollPhysics(),
                            slivers: [
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: EdgeInsets.fromLTRB(18, mq.padding.top + 76, 18, 6),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text('YOUR PRIVATE SPACE', style: TextStyle(color: p.accent, fontSize: 10, letterSpacing: 2.0, fontWeight: FontWeight.w800)),
                                                const SizedBox(height: 5),
                                                Text('Your Albums', style: TextStyle(color: p.text, fontSize: 27, height: 1.1, fontWeight: FontWeight.w800, letterSpacing: -0.8)),
                                                const SizedBox(height: 5),
                                                Text('${_albums.length} albums  ·  ${_albumCounts.values.fold<int>(0, (sum, count) => sum + count)} items secured', style: TextStyle(color: p.sub, fontSize: 12)),
                                              ],
                                            ),
                                          ),
                                          Container(
                                            width: 46, height: 46,
                                            decoration: BoxDecoration(
                                              borderRadius: BorderRadius.circular(16),
                                              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [p.accent.withValues(alpha: 0.24), p.accent.withValues(alpha: 0.07)]),
                                              border: Border.all(color: p.accent.withValues(alpha: 0.30)),
                                            ),
                                            child: Icon(Icons.shield_rounded, color: p.accent, size: 23),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 18),
                                      Container(
                                        height: 50,
                                        decoration: BoxDecoration(color: p.glass, borderRadius: BorderRadius.circular(17), border: Border.all(color: p.border)),
                                        child: TextField(
                                          controller: _searchController,
                                          onChanged: (value) => setState(() => _searchQuery = value),
                                          style: TextStyle(color: p.text, fontSize: 14),
                                          cursorColor: p.accent,
                                          decoration: InputDecoration(
                                            hintText: 'Search your albums...', hintStyle: TextStyle(color: p.sub, fontSize: 13),
                                            prefixIcon: Icon(Icons.search_rounded, color: p.sub, size: 22),
                                            suffixIcon: _searchQuery.isEmpty ? null : IconButton(icon: Icon(Icons.close_rounded, color: p.sub), onPressed: () { _searchController.clear(); setState(() => _searchQuery = ''); }),
                                            border: InputBorder.none, contentPadding: const EdgeInsets.symmetric(vertical: 14),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Row(
                                        children: [
                                          Text(_searchQuery.isEmpty ? 'COLLECTIONS' : 'SEARCH RESULTS', style: TextStyle(color: p.sub, fontSize: 10, letterSpacing: 1.7, fontWeight: FontWeight.w800)),
                                          const Spacer(),
                                          Text('${_visibleAlbums.length + 1} folders', style: TextStyle(color: p.sub, fontSize: 11)),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (_searchQuery.trim().isNotEmpty && _visibleAlbums.isEmpty)
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(24, 34, 24, 18),
                                    child: Column(
                                      children: [
                                        Container(
                                          width: 72, height: 72,
                                          decoration: BoxDecoration(color: p.glass, borderRadius: BorderRadius.circular(24), border: Border.all(color: p.border)),
                                          child: Icon(Icons.search_off_rounded, size: 32, color: p.sub),
                                        ),
                                        const SizedBox(height: 14),
                                        Text('No albums found', style: TextStyle(color: p.text, fontSize: 16, fontWeight: FontWeight.w700)),
                                        const SizedBox(height: 5),
                                        Text('Try another album name.', style: TextStyle(color: p.sub, fontSize: 12)),
                                      ],
                                    ),
                                  ),
                                ),
                              SliverPadding(
                                padding: const EdgeInsets.fromLTRB(16, 10, 16, 120),
                                sliver: SliverGrid(
                                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: mq.size.width >= 720 ? 3 : 2,
                                    crossAxisSpacing: 13, mainAxisSpacing: 13,
                                    childAspectRatio: mq.size.width >= 720 ? 0.92 : 0.83,
                                  ),
                                  delegate: SliverChildBuilderDelegate(
                                    (context, index) {
                                      final visibleAlbums = _visibleAlbums;
                                      // Recycle Bin remains pinned as the final card in the grid.
                                      if (index == visibleAlbums.length) {
                                        return _AlbumCard(
                                          name: 'Recycle Bin',
                                          count: _binCount,
                                          cover: null,
                                          showCover: false,
                                          selected: false,
                                          selecting: false,
                                          isBin: true,
                                          p: p,
                                          onTap: () {
                                            if (!selecting) {
                                              Navigator.push(context, MaterialPageRoute(builder: (_) => const BinScreen())).then((_) => _loadAlbums());
                                            }
                                          },
                                          onLongPress: () {}, // Do nothing for Bin
                                        );
                                      }

                                      final name = _visibleAlbums[index];
                                      final isSelected = _selectedAlbum == name;
                                      return _AlbumCard(
                                        name: name,
                                        count: _albumCounts[name] ?? 0,
                                        cover: _albumCovers[name],
                                        showCover: _showAlbumCovers,
                                        selected: isSelected,
                                        selecting: selecting,
                                        isBin: false,
                                        p: p,
                                        onTap: () {
                                          if (selecting) {
                                            setState(() => _selectedAlbum = isSelected ? null : name);
                                          } else {
                                            Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumViewScreen(albumName: name))).then((_) => _loadAlbums());
                                          }
                                        },
                                        onLongPress: () {
                                          HapticFeedback.mediumImpact();
                                          setState(() => _selectedAlbum = name);
                                        },
                                      );
                                    },
                                    childCount: _visibleAlbums.length + 1, // +1 for the Bin card
                                  ),
                                ),
                              ),
                            ],
                          ),
              ),

              // ─── TOP GLASS BAR ───
              Positioned(
                top: 0, left: 0, right: 0,
                child: _Glass(
                  p: p, radius: 0, blur: 28, border: Border(bottom: BorderSide(color: p.border)),
                  child: Padding(
                    padding: EdgeInsets.only(top: mq.padding.top),
                    child: SizedBox(
                      height: 56,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: selecting
                            ? Row(
                                key: const ValueKey('select'),
                                children: [
                                  IconButton(icon: Icon(Icons.close_rounded, color: p.text), onPressed: () => setState(() => _selectedAlbum = null)),
                                  Expanded(child: Text('Album Selected', style: TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.bold))),
                                ],
                              )
                            : Row(
                                key: const ValueKey('normal'),
                                children: [
                                  const SizedBox(width: 8),
                                  IconButton(icon: Icon(Icons.arrow_back_ios_new_rounded, color: p.text, size: 20), onPressed: () => Navigator.pop(context)),
                                  Expanded(child: Text('Secure Vault', style: TextStyle(color: p.text, fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: -0.5))),
                                  
                                  // Album covers + sorting settings
                                  IconButton(
                                    tooltip: 'Album settings',
                                    icon: Icon(Icons.tune_rounded, color: p.text),
                                    onPressed: () => _showAlbumSettings(p),
                                  ),

                                  // Duplicate Finder: compare Gallery and Vault files.
                                  IconButton(
                                    tooltip: 'Duplicate Finder',
                                    icon: Icon(Icons.content_copy_rounded, color: p.text),
                                    onPressed: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => const DuplicateFinderScreen(),
                                        ),
                                      );
                                    },
                                  ),

                                  // Backup / Restore Menu
                                  PopupMenuButton<String>(
                                    icon: Icon(Icons.more_vert_rounded, color: p.text),
                                    color: p.surface,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                    onSelected: (val) {
                                      if (val == 'backup') _backup();
                                      if (val == 'restore') _restore();
                                    },
                                    itemBuilder: (_) => [
                                      PopupMenuItem(value: 'backup', child: Row(children: [Icon(Icons.cloud_upload_rounded, color: p.text, size: 20), const SizedBox(width: 12), Text('Backup All', style: TextStyle(color: p.text))])),
                                      PopupMenuItem(value: 'restore', child: Row(children: [Icon(Icons.cloud_download_rounded, color: p.text, size: 20), const SizedBox(width: 12), Text('Restore Vault', style: TextStyle(color: p.text))])),
                                    ],
                                  ),
                                  const SizedBox(width: 4),
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
              ),

              // ─── BOTTOM GLASS ACTIONS BAR ───
              Positioned(
                left: 12, right: 12, bottom: mq.padding.bottom + 12,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  transitionBuilder: (c, a) => FadeTransition(opacity: a, child: SlideTransition(position: Tween(begin: const Offset(0, 0.6), end: Offset.zero).animate(a), child: c)),
                  child: selecting
                      ? _Glass(
                          key: const ValueKey('album_actions'),
                          p: p, radius: 28, blur: 26,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                _ActionBtn(icon: Icons.cloud_upload_rounded, label: 'Backup Album', color: p.accent, onTap: () => _backup(albumName: _selectedAlbum)),
                                _ActionBtn(icon: Icons.delete_outline_rounded, label: 'Delete Album', color: Colors.redAccent, onTap: () => _deleteAlbum(_selectedAlbum!)),
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

        // ─── FAB (New Album) ───
        floatingActionButton: !selecting
            ? ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: FloatingActionButton.extended(
                    onPressed: () => _createNewAlbum(p),
                    backgroundColor: p.accent.withValues(alpha: 0.8),
                    elevation: 0,
                    icon: const Icon(Icons.add_rounded, color: Colors.white),
                    label: const Text('New Album', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ),
              )
            : null,
      ),
    );
  }
}

// ─── ALBUM CARD WIDGET ───
class _AlbumCard extends StatelessWidget {
  const _AlbumCard({
    required this.name,
    required this.count,
    required this.cover,
    required this.showCover,
    required this.selected,
    required this.selecting,
    required this.isBin,
    required this.p,
    required this.onTap,
    required this.onLongPress,
  });
  final String name;
  final int count;
  final String? cover;
  final bool showCover;
  final bool selected;
  final bool selecting;
  final bool isBin;
  final AppPalette p;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final coverPath = cover;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: selected
                ? [p.accent.withValues(alpha: 0.20), p.glass]
                : [p.glass, p.surface.withValues(alpha: 0.78)],
          ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: selected ? p.accent : p.border.withValues(alpha: 0.85), width: selected ? 1.8 : 1),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 18, offset: const Offset(0, 7))],
        ),
        child: Padding(
          padding: const EdgeInsets.all(4.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(
                        color: p.surface,
                        child: Icon(
                          isBin ? Icons.delete_outline_rounded : Icons.folder_shared_rounded, 
                          size: 60, 
                          color: isBin ? Colors.redAccent.withValues(alpha: 0.8) : (selected ? p.accent : p.accent.withValues(alpha: 0.6))
                        ),
                      ),
                      if (showCover && coverPath != null && coverPath.isNotEmpty && !isBin)
                        Image.file(
                          File(coverPath),
                          fit: BoxFit.cover,
                          cacheWidth: 500,
                          gaplessPlayback: true,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                      if (showCover && coverPath != null && coverPath.isNotEmpty && !isBin)
                        DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black.withValues(alpha: 0.04), Colors.transparent, Colors.black.withValues(alpha: 0.22)]))),
                      Positioned(
                        top: 9, right: 9,
                        child: Container(
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.30), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white.withValues(alpha: 0.18))),
                          child: Icon(isBin ? Icons.delete_outline_rounded : Icons.folder_rounded, size: 15, color: Colors.white),
                        ),
                      ),
                      if (selected) ColoredBox(color: p.accent.withValues(alpha: 0.25)),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(11, 10, 9, 11),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: isBin ? Colors.redAccent : p.text, fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
                          const SizedBox(height: 2),
                          Text(isBin ? (count > 0 ? '$count items' : 'Empty') : '$count ${count == 1 ? 'item' : 'items'}', style: TextStyle(color: p.sub, fontSize: 11, fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ),
                    if (selecting && !isBin)
                      Icon(selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, color: selected ? p.accent : p.sub, size: 22),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}