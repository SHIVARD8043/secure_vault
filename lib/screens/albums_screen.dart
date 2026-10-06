import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import '../core/vault_service.dart';
import '../db/database_helper.dart';
import '../db/vault_queries.dart';
import '../core/backup_service.dart';
import 'album_view_screen.dart';

// ════════════════════════════════════════════════════════════════════
//  PALETTE & GLASS (Home Screen నుంచి తెచ్చినవి)
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
//  ALBUMS (VAULT) SCREEN
// ════════════════════════════════════════════════════════════════════
class AlbumsScreen extends StatefulWidget {
  const AlbumsScreen({super.key});
  @override
  State<AlbumsScreen> createState() => _AlbumsScreenState();
}

class _AlbumsScreenState extends State<AlbumsScreen> {
  List<Map<String, dynamic>> _albums = [];
  bool _loading = true;
  final _P p = _P.dark; // Vault ఎప్పుడూ డార్క్ థీమ్ లో ఉంటేనే ఆ ఫీల్ వస్తుంది 🔒

  @override
  void initState() {
    super.initState();
    _loadAlbums();
  }

  Future<void> _loadAlbums() async {
    final data = await DatabaseHelper.instance.fetchAlbums();
    if (!mounted) return;
    setState(() {
      _albums = data;
      _loading = false;
    });
  }

  // ─── BACKUP & RESTORE ───
  Future<void> _backup() async {
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    try {
      // ఇక్కడ createBackup() అని మార్చాం 
      final path = await BackupService().createBackup(); 
      
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Backup Saved: $path ✅')));
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Backup Failed: $e ❌')));
    }
  }

  Future<void> _restore() async {
    const XTypeGroup zipTypeGroup = XTypeGroup(label: 'Zip Files', extensions: ['zip']);
    final XFile? file = await openFile(acceptedTypeGroups: [zipTypeGroup]);
    
    if (file == null || !mounted) return;
    final path = file.path;

    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    
    try {
      final n = await BackupService().restore(File(path)); // <-- Ikkada BackupService
      await File(path).delete().catchError((_) => File(path)); 
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n photos restored! 🔄')));
      _loadAlbums();
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Restore failed: $e ❌')));
    }
  }

  // ─── NEW ALBUM ───
  Future<void> _createNewAlbum() async {
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
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text('Create', style: TextStyle(color: p.accent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (name != null && name.isNotEmpty) {
      // ఇక్కడ ఆల్బమ్ క్రియేట్ చేయడానికి లాజిక్ (ఉదాహరణకి డేటాబేస్ లోకి ఇన్సర్ట్ చేయడం)
      // ప్రస్తుతానికి రిఫ్రెష్ చేస్తున్నాం
      _loadAlbums();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    
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
                                padding: EdgeInsets.only(top: mq.padding.top + 70, left: 16, right: 16, bottom: 100),
                                sliver: SliverGrid(
                                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 2, crossAxisSpacing: 16, mainAxisSpacing: 16, childAspectRatio: 0.85
                                  ),
                                  delegate: SliverChildBuilderDelegate(
                                    (context, index) {
                                      final album = _albums[index];
                                      final name = album['albumName'] as String;
                                      return _AlbumCard(name: name, p: p);
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
                      child: Row(
                        children: [
                          const SizedBox(width: 8),
                          IconButton(
                            icon: Icon(Icons.arrow_back_ios_new_rounded, color: p.text, size: 20),
                            onPressed: () => Navigator.pop(context),
                          ),
                          Expanded(
                            child: Text('Secure Vault', style: TextStyle(color: p.text, fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: -0.5)),
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
                              PopupMenuItem(value: 'backup', child: Row(children: [Icon(Icons.cloud_upload_rounded, color: p.text, size: 20), const SizedBox(width: 12), Text('Backup Vault', style: TextStyle(color: p.text))])),
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
            ],
          ),
        ),
        
        // ─── FAB (Glass Style) ───
        floatingActionButton: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: FloatingActionButton.extended(
              onPressed: _createNewAlbum,
              backgroundColor: p.accent.withValues(alpha: 0.8),
              elevation: 0,
              icon: const Icon(Icons.add_rounded, color: Colors.white),
              label: const Text('New Album', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── ALBUM CARD WIDGET ───
class _AlbumCard extends StatelessWidget {
  const _AlbumCard({required this.name, required this.p});
  final String name;
  final _P p;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Navigator.push(context, MaterialPageRoute(
          builder: (_) => AlbumViewScreen(albumName: name) 
        ));
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: p.glass,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: p.border),
        ),
        child: Padding(
          padding: const EdgeInsets.all(4.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: ColoredBox(
                    color: p.surface,
                    child: Icon(Icons.folder_shared_rounded, size: 60, color: p.accent.withValues(alpha: 0.6)),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text('Locked Photos', style: TextStyle(color: p.sub, fontSize: 12)),
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