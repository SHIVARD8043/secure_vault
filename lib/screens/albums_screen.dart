import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_selector/file_selector.dart';

import '../core/theme_provider.dart'; // Theme Provider
import '../core/backup_service.dart';
import '../core/vault_service.dart';
import '../db/database_helper.dart';
import '../db/vault_queries.dart';
import 'album_view_screen.dart';
import 'bin_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _loadAlbums();
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
        // rows are newest first, so first hit per album = latest
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

        // డమ్మీ ఫోల్డర్ ('folder') ని ఫోటో కౌంట్ లోకి తీసుకోకుండా అడ్డుకుంటున్నాం
        if (item.type != 'folder') {
          counts[item.albumName] = (counts[item.albumName] ?? 0) + 1;
        }
      }
    }

    final dbAlbums = await DatabaseHelper.instance.fetchAlbums();
    albumNames.addAll(dbAlbums.map((e) => e['albumName'] as String));

    final covers = await _loadCovers();

    if (mounted) {
      setState(() {
        _binCount = bin;
        _albumCounts = counts;
        _albumCovers = covers;
        _albums = albumNames.toList()..sort();
        _loading = false;
      });
    }
  }

  // ─── BACKUP (Center Dialog with Progress) ───
  Future<void> _backup({String? albumName}) async {
    final p = context.read<ThemeProvider>().p;
    
    // ప్రోగ్రెస్ ని రియల్ టైమ్ లో అప్‌డేట్ చేయడానికి Notifiers వాడుతున్నాం
    final progressVal = ValueNotifier<double>(0.0);
    final statusText = ValueNotifier<String>('ప్రిపేర్ అవుతోంది...');
    final dialogState = ValueNotifier<int>(0); // 0: Loading, 1: Success, 2: Error

    // 1. సెంటర్ లో డైలాగ్ ఓపెన్ చేస్తున్నాం
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        content: ValueListenableBuilder<int>(
          valueListenable: dialogState,
          builder: (ctx, state, _) {
            // ── SUCCESS UI ──
            if (state == 1) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_circle_rounded, color: Colors.green, size: 64),
                  const SizedBox(height: 16),
                  Text('Backup Finished! 🎉', style: TextStyle(color: p.text, fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(albumName != null ? '$albumName ఆల్బమ్ Downloads ఫోల్డర్ లో సేవ్ అయింది.' : 'మొత్తం బ్యాకప్ Downloads ఫోల్డర్ లో సేవ్ అయింది.', style: TextStyle(color: p.sub, fontSize: 14), textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: p.accent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: const EdgeInsets.symmetric(vertical: 12)),
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('OK', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  )
                ],
              );
            } 
            // ── ERROR UI ──
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
                      child: const Text('Close', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  )
                ],
              );
            }

            // ── LOADING UI (Progress Bar) ──
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
                Text('బ్యాకప్ అవుతోంది...', style: TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.bold)),
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

    // 2. బ్యాక్‌గ్రౌండ్ లో బ్యాకప్ ప్రాసెస్ స్టార్ట్ చేస్తున్నాం
    try {
      final tempZip = await BackupService().createBackup(
        albumName: albumName,
        onProgress: (done, total) {
          // ఇక్కడి నుంచే ప్రోగ్రెస్ బార్ కి డేటా వెళ్తుంది
          progressVal.value = done / total;
          statusText.value = '$done / $total ఫైల్స్ సేవ్ అయ్యాయి';
        },
      );
      
      statusText.value = 'Downloads లోకి పంపుతోంది...';
      progressVal.value = 0.0; // ఫైల్ కాపీ అయ్యేటప్పుడు లోడింగ్ తిరుగుతుంది
      
      final savedPath = await BackupService().exportToDownloads(tempZip);
      
      if (savedPath != null) {
        dialogState.value = 1; // Success స్టేట్ కి మారుస్తున్నాం
        if (mounted) setState(() => _selectedAlbum = null);
      } else {
        statusText.value = 'Storage Permission లేదు. యాప్ సెట్టింగ్స్ లో పర్మిషన్ ఇవ్వండి.';
        dialogState.value = 2; // Error స్టేట్
      }
    } catch (e) {
      statusText.value = e.toString();
      dialogState.value = 2; // Error స్టేట్
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
                  Text('${restoredCount.value} ఫోటోలు / వీడియోలు రిస్టోర్ అయ్యాయి 🔄', style: TextStyle(color: p.sub, fontSize: 14), textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: p.accent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: const EdgeInsets.symmetric(vertical: 12)),
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('OK', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
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
                Text('డేటా రిస్టోర్ అవుతోంది...', style: TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text('దయచేసి వేచి ఉండండి', style: TextStyle(color: p.sub, fontSize: 14)),
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
      dialogState.value = 1; // Success
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
  Future<void> _createNewAlbum(AppPalette p) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        title: Text('కొత్త ఆల్బమ్', style: TextStyle(color: p.text, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: ctrl,
          style: TextStyle(color: p.text),
          decoration: InputDecoration(hintText: 'ఆల్బమ్ పేరు...', hintStyle: TextStyle(color: p.sub)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text('Create', style: TextStyle(color: p.accent, fontWeight: FontWeight.bold))),
        ],
      ),
    );

    if (name != null && name.isNotEmpty) {
      try {
        final db = await DatabaseHelper.instance.database;

        // ఆల్బమ్ పేరుని నిలబెట్టడానికి ఒక దాచిన 'డమ్మీ' రికార్డ్ వేస్తున్నాం
        await db.insert('vault_items', {
          'originalName': 'dummy_folder_$name',
          'encryptedPath': 'dummy', // ఫైల్ పాత్ అక్కర్లేదు
          'thumbnailPath': null,
          'type': 'folder', // 'image' కాదు కాబట్టి ఫోటోల్లో కనిపించదు
          'albumName': name,
          'addedDate': DateTime.now().toIso8601String(),
          'isDeleted': 0,
        });
      } catch (e) {
        debugPrint('Album Creation Error: $e');
      }

      _loadAlbums();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final p = context.watch<ThemeProvider>().p; // Theme Provider Integration
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
                    : _albums.isEmpty
                        ? Center(child: Text('Vault ఖాళీగా ఉంది 🔒', style: TextStyle(color: p.sub, fontSize: 18)))
                        : CustomScrollView(
                            physics: const BouncingScrollPhysics(),
                            slivers: [
                              SliverPadding(
                                padding: EdgeInsets.only(top: mq.padding.top + 70, left: 16, right: 16, bottom: 120),
                                sliver: SliverGrid(
                                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 2, crossAxisSpacing: 16, mainAxisSpacing: 16, childAspectRatio: 0.85,
                                  ),
                                  delegate: SliverChildBuilderDelegate(
                                    (context, index) {
                                      final name = _albums[index];
                                      final isSelected = _selectedAlbum == name;
                                      return _AlbumCard(
                                        name: name,
                                        count: _albumCounts[name] ?? 0,
                                        cover: _albumCovers[name],
                                        selected: isSelected,
                                        selecting: selecting,
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
                                    childCount: _albums.length,
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
                                  IconButton(
                                    tooltip: 'Recycle Bin',
                                    icon: Badge(
                                      isLabelVisible: _binCount > 0,
                                      label: Text('$_binCount'),
                                      backgroundColor: Colors.redAccent,
                                      child: Icon(Icons.delete_outline_rounded, color: p.text, size: 24),
                                    ),
                                    onPressed: () {
                                      Navigator.push(context, MaterialPageRoute(builder: (_) => const BinScreen())).then((_) => _loadAlbums());
                                    },
                                  ),
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
    required this.selected,
    required this.selecting,
    required this.p,
    required this.onTap,
    required this.onLongPress,
  });
  final String name;
  final int count;
  final String? cover;
  final bool selected;
  final bool selecting;
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
          color: selected ? p.accent.withValues(alpha: 0.15) : p.glass,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: selected ? p.accent : p.border, width: selected ? 2 : 1),
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
                        child: Icon(Icons.folder_shared_rounded, size: 60, color: selected ? p.accent : p.accent.withValues(alpha: 0.6)),
                      ),
                      if (coverPath != null && coverPath.isNotEmpty)
                        Image.file(
                          File(coverPath),
                          fit: BoxFit.cover,
                          cacheWidth: 400,
                          gaplessPlayback: true,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                      if (selected) ColoredBox(color: p.accent.withValues(alpha: 0.25)),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontSize: 16, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Text('$count Photos', style: TextStyle(color: p.sub, fontSize: 12)),
                        ],
                      ),
                    ),
                    if (selecting)
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