import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import '../core/vault_service.dart';
import '../db/database_helper.dart';
import 'albums_screen.dart';
import '../db/vault_queries.dart';
import 'gallery_actions.dart'; // NEW: share / copy / move / bin + metadata sheet

// ════════════════════════════════════════════════════════════════════
//  PALETTE  (dark ⇄ light, animated)
// ════════════════════════════════════════════════════════════════════
class _P {
  const _P({
    required this.bg,
    required this.bg2,
    required this.text,
    required this.sub,
    required this.glass,
    required this.border,
    required this.bar,
    required this.accent,
    required this.surface,
  });

  final Color bg, bg2, text, sub, glass, border, bar, accent, surface;

  static const dark = _P(
    bg: Color(0xFF090A0F),
    bg2: Color(0xFF14161F),
    text: Color(0xFFF4F5FA),
    sub: Color(0xFF9AA1B5),
    glass: Color(0x14FFFFFF),
    border: Color(0x26FFFFFF),
    bar: Color(0x990A0B10),
    accent: Color(0xFF7C9CFF),
    surface: Color(0xFF1B1E2A),
  );

  static const light = _P(
    bg: Color(0xFFEDEFF6),
    bg2: Color(0xFFFFFFFF),
    text: Color(0xFF12141C),
    sub: Color(0xFF6B7285),
    glass: Color(0x99FFFFFF),
    border: Color(0xE6FFFFFF),
    bar: Color(0xB8FFFFFF),
    accent: Color(0xFF3D5AFE),
    surface: Color(0xFFFFFFFF),
  );

  static _P mix(double t) => _P(
        bg: Color.lerp(dark.bg, light.bg, t)!,
        bg2: Color.lerp(dark.bg2, light.bg2, t)!,
        text: Color.lerp(dark.text, light.text, t)!,
        sub: Color.lerp(dark.sub, light.sub, t)!,
        glass: Color.lerp(dark.glass, light.glass, t)!,
        border: Color.lerp(dark.border, light.border, t)!,
        bar: Color.lerp(dark.bar, light.bar, t)!,
        accent: Color.lerp(dark.accent, light.accent, t)!,
        surface: Color.lerp(dark.surface, light.surface, t)!,
      );

  // NEW: palette → colors used by gallery_actions.dart dialogs
  ActionColors get actionColors =>
      ActionColors(surface: surface, text: text, sub: sub, accent: accent, border: border);
}

// ════════════════════════════════════════════════════════════════════
//  SMALL MODELS
// ════════════════════════════════════════════════════════════════════
class _Group {
  _Group(this.label, this.start, this.year);
  final String label;
  final int start; // index in _items
  final int year;
  int count = 1;
}

class _Row {
  const _Row(this.header, this.group, this.start, this.count, this.top, this.height);
  final bool header;
  final int group;
  final int start; // index in _items of first photo in this row
  final int count;
  final double top;
  final double height;
}

class _Layout {
  _Layout(this.width, this.cols, this.cell, this.thumbPx, this.rows, this.total);
  final double width;
  final int cols;
  final double cell;
  final int thumbPx;
  final List<_Row> rows;
  final double total;
}

// ════════════════════════════════════════════════════════════════════
//  GLASS CONTAINER  (frosted blur)
// ════════════════════════════════════════════════════════════════════
class _Glass extends StatelessWidget {
  const _Glass({
    super.key,
    required this.p,
    required this.child,
    this.radius = 24,
    this.blur = 22,
    this.border,
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
          decoration: BoxDecoration(
            color: p.bar,
            borderRadius: br,
            border: border ?? (radius > 0 ? Border.all(color: p.border) : null),
          ),
          child: child,
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  SELECTION CHECK BADGE
// ════════════════════════════════════════════════════════════════════
class _Check extends StatelessWidget {
  const _Check({required this.on, required this.p, this.overlay = true});
  final bool on, overlay;
  final _P p;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on
            ? p.accent
            : (overlay ? Colors.black.withValues(alpha: 0.28) : Colors.transparent),
        border: on
            ? null
            : Border.all(color: overlay ? Colors.white : p.sub.withValues(alpha: 0.6), width: 1.6),
      ),
      child: AnimatedScale(
        scale: on ? 1 : 0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        child: const Icon(Icons.check_rounded, size: 16, color: Colors.white),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  HERO SHUTTLE (thumbnail → preview, rounded corners morph)
// ════════════════════════════════════════════════════════════════════
HeroFlightShuttleBuilder _shuttle(ImageProvider img) {
  return (ctx, anim, dir, fromCtx, toCtx) => AnimatedBuilder(
        animation: anim,
        builder: (_, __) {
          final t = dir == HeroFlightDirection.push ? anim.value : 1 - anim.value;
          final r = lerpDouble(11, 0, Curves.easeOut.transform(t.clamp(0.0, 1.0)))!;
          return ClipRRect(
            borderRadius: BorderRadius.circular(r),
            child: Image(image: img, fit: BoxFit.cover, gaplessPlayback: true),
          );
        },
      );
}

// ════════════════════════════════════════════════════════════════════
//  GRID TILE
// ════════════════════════════════════════════════════════════════════
class _Tile extends StatelessWidget {
  const _Tile({
    super.key,
    required this.asset,
    required this.px,
    required this.selected,
    required this.selecting,
    required this.p,
  });
  final AssetEntity asset;
  final int px;
  final bool selected, selecting;
  final _P p;

  @override
  Widget build(BuildContext context) {
    final provider = AssetEntityImageProvider(
      asset,
      isOriginal: false,
      thumbnailSize: ThumbnailSize.square(px),
    );
    return RepaintBoundary(
      child: Stack(fit: StackFit.expand, children: [
        AnimatedScale(
          scale: selected ? 0.86 : 1,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          child: Hero(
            tag: 'photo_${asset.id}',
            flightShuttleBuilder: _shuttle(provider),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: p.glass,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: p.border),
              ),
              child: Padding(
                padding: const EdgeInsets.all(1.5),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9.5),
                  child: Stack(fit: StackFit.expand, children: [
                    Image(
                      image: provider,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      frameBuilder: (c, child, frame, sync) => sync
                          ? child
                          : AnimatedOpacity(
                              opacity: frame == null ? 0 : 1,
                              duration: const Duration(milliseconds: 220),
                              child: child),
                    ),
                    // glass sheen
                    const IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.center,
                            colors: [Color(0x26FFFFFF), Color(0x00FFFFFF)],
                          ),
                        ),
                      ),
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      color: selected ? p.accent.withValues(alpha: 0.22) : Colors.transparent,
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
        if (selecting)
          Positioned(top: 7, left: 7, child: _Check(on: selected, p: p)),
      ]),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  HOME GALLERY SCREEN
// ════════════════════════════════════════════════════════════════════
class HomeGalleryScreen extends StatefulWidget {
  const HomeGalleryScreen({super.key});
  @override
  State<HomeGalleryScreen> createState() => _HomeGalleryScreenState();
}

class _HomeGalleryScreenState extends State<HomeGalleryScreen>
    with SingleTickerProviderStateMixin {
  static const _pageSize = 120;
  static const _hPad = 4.0, _gap = 3.0, _headerH = 58.0;

  final _scroll = ScrollController();
  final List<AssetEntity> _items = [];
  final List<_Group> _groups = [];
  final Map<int, int> _yearCounts = {};
  final Map<String, int> _yearById = {};
  final Set<String> _selected = {};

  AssetPathEntity? _album;
  bool _hasMore = true, _loading = false, _ready = false;
  int _gen = 0;
  int _gridColumns = 3;
  _Layout? _layout;
  Future<void>? _loadAllFuture;

  // theme
  late final AnimationController _themeCtrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 450));
  bool _light = false;
  _P get _pal => _P.mix(Curves.easeInOut.transform(_themeCtrl.value));

  // drag-select
  bool _dragActive = false, _dragSelect = true;
  int _anchor = 0, _lastIdx = -1;
  Set<String> _dragBase = {};
  Offset? _lastPointer;
  Timer? _autoTimer;
  double _topPad = 0, _viewH = 0, _gw = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.hasClients &&
          _scroll.position.pixels > _scroll.position.maxScrollExtent - 1200) {
        _loadMore();
      }
    });
    _reload();
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _themeCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ─────────────────────────── DATA ───────────────────────────
  Future<void> _reload() async {
    final gen = ++_gen;
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.isAuth) {
      PhotoManager.openSetting();
      return;
    }
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
      filterOption: FilterOptionGroup(
          orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)]),
    );
    if (!mounted || gen != _gen) return;
    if (albums.isEmpty) {
      setState(() => _ready = true);
      return;
    }
    _album = albums.first;
    final want = math.max(_pageSize, _items.length);
    final first = await _album!.getAssetListRange(start: 0, end: want);
    if (!mounted || gen != _gen) return;
    setState(() {
      _items
        ..clear()
        ..addAll(first);
      _hasMore = first.length == want;
      _loadAllFuture = null;
      _loading = false;
      _regroup();
      _ready = true;
    });
  }

  Future<void> _loadMore({int size = _pageSize}) async {
    if (_loading || !_hasMore || _album == null) return;
    _loading = true;
    final gen = _gen;
    try {
      final batch = await _album!
          .getAssetListRange(start: _items.length, end: _items.length + size);
      if (!mounted || gen != _gen) return;
      setState(() {
        _items.addAll(batch);
        if (batch.length < size) _hasMore = false;
        _regroup();
      });
    } finally {
      _loading = false;
    }
  }

  Future<void> _loadAll() async {
    final gen = _gen;
    while (mounted && gen == _gen && _hasMore && _album != null) {
      if (_loading) {
        await Future.delayed(const Duration(milliseconds: 40));
        continue;
      }
      await _loadMore(size: 1000);
    }
  }

  void _regroup() {
    _layout = null;
    _groups.clear();
    _yearCounts.clear();
    _yearById.clear();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    String? lastKey;
    for (var i = 0; i < _items.length; i++) {
      final a = _items[i];
      final d = a.createDateTime;
      final day = DateTime(d.year, d.month, d.day);
      final String key = day == today
          ? 'T'
          : day == yesterday
              ? 'Y'
              : d.year == now.year
                  ? 'd${day.millisecondsSinceEpoch}'
                  : 'm${d.year}-${d.month}';
      if (key != lastKey) {
        final label = key == 'T'
            ? "ఈరోజు (Today)"
            : key == 'Y'
                ? "నిన్న (Yesterday)"
                : d.year == now.year
                    ? DateFormat('EEE, MMM d').format(d)
                    : DateFormat('MMMM yyyy').format(d);
        _groups.add(_Group(label, i, d.year));
        lastKey = key;
      } else {
        _groups.last.count++;
      }
      _yearCounts[d.year] = (_yearCounts[d.year] ?? 0) + 1;
      _yearById[a.id] = d.year;
    }
  }

  _Layout _layoutFor(double width, double dpr) {
    final l = _layout;
    if (l != null && l.width == width && l.cols == _gridColumns) return l;
    final cell = (width - _hPad * 2 - _gap * (_gridColumns - 1)) / _gridColumns;
    final px = (((cell * dpr) / 50).ceil() * 50).clamp(100, 600).toInt();
    final rows = <_Row>[];
    var y = 0.0;
    for (var g = 0; g < _groups.length; g++) {
      final grp = _groups[g];
      rows.add(_Row(true, g, grp.start, grp.count, y, _headerH));
      y += _headerH;
      final n = (grp.count / _gridColumns).ceil();
      for (var r = 0; r < n; r++) {
        final s = r * _gridColumns;
        rows.add(_Row(false, g, grp.start + s, math.min(_gridColumns, grp.count - s), y, cell + _gap));
        y += cell + _gap;
      }
    }
    return _layout = _Layout(width, _gridColumns, cell, px, rows, y);
  }

  // ─────────────────────────── SELECTION ───────────────────────────
  void _sel(VoidCallback f) {
    setState(f);
    if (_selected.isNotEmpty) _loadAllFuture ??= _loadAll();
  }

  void _toggle(AssetEntity a) =>
      _sel(() => _selected.contains(a.id) ? _selected.remove(a.id) : _selected.add(a.id));

  void _toggleGroup(int gi) {
    final g = _groups[gi];
    final ids = _items.sublist(g.start, g.start + g.count).map((e) => e.id).toList();
    final all = ids.every(_selected.contains);
    HapticFeedback.selectionClick();
    _sel(() => all ? _selected.removeAll(ids) : _selected.addAll(ids));
  }

  Future<void> _toggleYear(int year) async {
    HapticFeedback.selectionClick();
    _loadAllFuture ??= _loadAll();
    await _loadAllFuture;
    if (!mounted) return;
    final ids = _items.where((a) => a.createDateTime.year == year).map((a) => a.id).toList();
    final all = ids.every(_selected.contains);
    _sel(() => all ? _selected.removeAll(ids) : _selected.addAll(ids));
  }

  // ─────────────────────────── HIT TEST (math based, no keys) ───────────────────────────
  (_Row, int)? _hit(Offset local) {
    final L = _layout;
    if (L == null || !_scroll.hasClients || L.rows.isEmpty) return null;
    final y = _scroll.offset + local.dy - _topPad;
    if (y < 0 || y > L.total) return null;
    var lo = 0, hi = L.rows.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (L.rows[mid].top <= y) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final r = L.rows[lo];
    if (r.header) return (r, r.start);
    final col = ((local.dx - _hPad) / (L.cell + _gap)).floor().clamp(0, r.count - 1);
    return (r, r.start + col);
  }

  void _tapUp(TapUpDetails d) {
    final hit = _hit(d.localPosition);
    if (hit == null) return;
    final (row, idx) = hit;
    if (row.header) {
      if (_selected.isNotEmpty || d.localPosition.dx > _gw - 80) _toggleGroup(row.group);
      return;
    }
    if (_selected.isNotEmpty) {
      _toggle(_items[idx]);
    } else {
      _openPreview(idx);
    }
  }

  // ─────────────────────────── DRAG SELECT (Google Photos style) ───────────────────────────
  void _dragStart(LongPressStartDetails d) {
    final hit = _hit(d.localPosition);
    if (hit == null || hit.$1.header) return;
    final idx = hit.$2;
    final id = _items[idx].id;
    _dragActive = true;
    _anchor = idx;
    _lastIdx = idx;
    _dragSelect = !_selected.contains(id);
    _dragBase = {..._selected};
    _lastPointer = d.localPosition;
    HapticFeedback.mediumImpact();
    _sel(() => _dragSelect ? _selected.add(id) : _selected.remove(id));
    _autoTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) => _autoScrollTick());
  }

  void _dragMove(LongPressMoveUpdateDetails d) {
    if (!_dragActive) return;
    _lastPointer = d.localPosition;
    _applyDrag();
  }

  void _dragEnd() {
    _dragActive = false;
    _autoTimer?.cancel();
    _autoTimer = null;
  }

  void _applyDrag() {
    final p = _lastPointer;
    if (p == null) return;
    final hit = _hit(p);
    if (hit == null) return;
    final c = hit.$2;
    if (c == _lastIdx) return;
    _lastIdx = c;
    final lo = math.min(_anchor, c), hi = math.max(_anchor, c);
    final next = {..._dragBase};
    for (var i = lo; i <= hi; i++) {
      _dragSelect ? next.add(_items[i].id) : next.remove(_items[i].id);
    }
    HapticFeedback.selectionClick();
    setState(() {
      _selected
        ..clear()
        ..addAll(next);
    });
  }

  void _autoScrollTick() {
    final p = _lastPointer;
    if (!_dragActive || p == null || !_scroll.hasClients) return;
    double v = 0;
    final up = (_topPad + 50 - p.dy) / 90;
    final down = (p.dy - (_viewH - 130)) / 90;
    if (up > 0) v = -up.clamp(0.0, 1.0) * 26;
    if (down > 0) v = down.clamp(0.0, 1.0) * 26;
    if (v == 0) return;
    final pos = _scroll.position;
    final target = (pos.pixels + v).clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if (target != pos.pixels) {
      _scroll.jumpTo(target);
      _lastIdx = -1; // force re-evaluate under finger
      _applyDrag();
    }
  }

  // ─────────────────────────── PREVIEW ───────────────────────────
  void _openPreview(int idx) {
    final px = _layout?.thumbPx ?? 250;
    Navigator.of(context).push(PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 420),
      reverseTransitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (_, __, ___) => _PreviewScreen(
        items: List.of(_items),
        initial: idx,
        thumbPx: px,
        onChanged: _reload, // NEW: refresh grid after move / bin from preview
      ),
      transitionsBuilder: (_, a, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: a, curve: Curves.easeOutCubic),
        child: child,
      ),
    ));
  }

  // ─────────────────────────── SHARE / COPY / MOVE / BIN (NEW) ───────────────────────────
  Future<void> _openActions() async {
    final chosen = _items.where((a) => _selected.contains(a.id)).toList();
    if (chosen.isEmpty) return;
    final changed = await runGalleryAction(context, _pal.actionColors, chosen);
    if (changed && mounted) {
      setState(_selected.clear);
      await _reload();
    }
  }

  // ─────────────────────────── VAULT / DELETE ───────────────────────────
  Future<String?> _showAlbumPicker() async {
    final albums = (await DatabaseHelper.instance.fetchAlbums())
        .map((e) => e['albumName'] as String)
        .toList();
    final ctrl = TextEditingController();
    final p = _pal;
    if (!mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        title: Text('లాక్ చేయడానికి ఆల్బమ్ ఎంచుకోండి',
            style: TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.w700)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: ctrl,
            style: TextStyle(color: p.text),
            decoration: InputDecoration(
                hintText: 'కొత్త ఆల్బమ్ పేరు', hintStyle: TextStyle(color: p.sub)),
          ),
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final a in albums)
              ActionChip(
                backgroundColor: p.bg2,
                side: BorderSide(color: p.border),
                label: Text(a, style: TextStyle(color: p.text)),
                onPressed: () => Navigator.pop(ctx, a),
              ),
          ]),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(
                  ctx, ctrl.text.trim().isEmpty ? 'My_Photos' : ctrl.text.trim()),
              child: const Text('Lock Here')),
        ],
      ),
    );
  }

  Future<void> _moveSelectedToVault() async {
    final chosen = _items.where((a) => _selected.contains(a.id)).toList();
    if (chosen.isEmpty) return;

    final targetAlbum = await _showAlbumPicker();
    if (targetAlbum == null) return;
    if (!mounted) return;

    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));

    final vault = VaultService();
    final toDeleteOS = <String>[];
    int successCount = 0;

    for (final a in chosen) {
      if (await vault.hideAsset(a, targetAlbum)) {
        successCount++;
        try {
          final file = await a.originFile;
          if (file != null && await file.exists()) {
            await file.delete();
          }
        } catch (e) {
          toDeleteOS.add(a.id);
        }
      }
    }

    if (toDeleteOS.isNotEmpty) {
      await PhotoManager.editor.deleteWithIds(toDeleteOS);
    }

    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$successCount/${chosen.length} ఫోటోలు $targetAlbum లో లాక్ అయ్యాయి 🔒')));

    setState(_selected.clear);
    await _reload();
  }

  Future<void> _deleteSelectedFromPhone() async {
    final chosen = _items.where((a) => _selected.contains(a.id)).toList();
    if (chosen.isEmpty) return;

    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));

    final toDeleteOS = <String>[];
    int successCount = 0;

    for (final a in chosen) {
      try {
        final file = await a.originFile;
        if (file != null && await file.exists()) {
          await file.delete();
          successCount++;
        }
      } catch (e) {
        toDeleteOS.add(a.id);
      }
    }

    if (toDeleteOS.isNotEmpty) {
      await PhotoManager.editor.deleteWithIds(toDeleteOS);
    }

    if (!mounted) return;
    Navigator.pop(context);

    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$successCount ఫోటోలు ఫోన్ నుంచి డిలీట్ అయ్యాయి 🗑️')));

    setState(_selected.clear);
    await _reload();
  }

  // ─────────────────────────── THEME ───────────────────────────
  void _toggleTheme() {
    HapticFeedback.lightImpact();
    setState(() => _light = !_light);
    _light ? _themeCtrl.forward() : _themeCtrl.reverse();
  }

  // ─────────────────────────── BUILD ───────────────────────────
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final selecting = _selected.isNotEmpty;

    return AnimatedBuilder(
      animation: _themeCtrl,
      builder: (context, _) {
        final p = _pal;
        _topPad = mq.padding.top + 56 + 8;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: _light ? Brightness.dark : Brightness.light,
            statusBarBrightness: _light ? Brightness.light : Brightness.dark,
          ),
          child: PopScope(
            canPop: !selecting,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) setState(_selected.clear);
            },
            child: Scaffold(
              backgroundColor: p.bg,
              body: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [p.bg, p.bg2]),
                ),
                child: Stack(children: [
                  Positioned.fill(child: _body(p, selecting, mq)),
                  _topBar(p, selecting, mq.padding.top),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: mq.padding.bottom + 12,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 260),
                      switchInCurve: Curves.easeOutCubic,
                      transitionBuilder: (c, a) => FadeTransition(
                        opacity: a,
                        child: SlideTransition(
                          position: Tween(begin: const Offset(0, 0.6), end: Offset.zero).animate(a),
                          child: c,
                        ),
                      ),
                      child: selecting ? _yearBar(p) : const SizedBox.shrink(),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _body(_P p, bool selecting, MediaQueryData mq) {
    if (!_ready) return Center(child: CircularProgressIndicator(color: p.accent));
    if (_items.isEmpty) {
      return Center(child: Text('No photos', style: TextStyle(color: p.sub, fontSize: 16)));
    }
    return LayoutBuilder(builder: (ctx, c) {
      _viewH = c.maxHeight;
      _gw = c.maxWidth;
      final L = _layoutFor(c.maxWidth, mq.devicePixelRatio);
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapUp: _tapUp,
        onLongPressStart: _dragStart,
        onLongPressMoveUpdate: _dragMove,
        onLongPressEnd: (_) => _dragEnd(),
        onLongPressCancel: _dragEnd,
        child: CustomScrollView(
          controller: _scroll,
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          cacheExtent: 1200,
          slivers: [
            SliverPadding(
              padding: EdgeInsets.only(top: _topPad, bottom: 120 + mq.padding.bottom),
              sliver: SliverVariedExtentList(
                itemExtentBuilder: (i, _) => L.rows[i].height,
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) => _rowWidget(L.rows[i], L, p, selecting),
                  childCount: L.rows.length,
                  addAutomaticKeepAlives: false,
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _rowWidget(_Row r, _Layout L, _P p, bool selecting) {
    if (r.header) return _header(r, p, selecting);
    return Padding(
      padding: const EdgeInsets.fromLTRB(_hPad, 0, _hPad, _gap),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var c = 0; c < r.count; c++) ...[
          if (c > 0) const SizedBox(width: _gap),
          SizedBox(
            width: L.cell,
            height: L.cell,
            child: _Tile(
              key: ValueKey(_items[r.start + c].id),
              asset: _items[r.start + c],
              px: L.thumbPx,
              selected: _selected.contains(_items[r.start + c].id),
              selecting: selecting,
              p: p,
            ),
          ),
        ],
      ]),
    );
  }

  Widget _header(_Row r, _P p, bool selecting) {
    final g = _groups[r.group];
    var all = false;
    if (selecting) {
      all = true;
      for (var i = g.start; i < g.start + g.count; i++) {
        if (!_selected.contains(_items[i].id)) {
          all = false;
          break;
        }
      }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Row(children: [
          Expanded(
            child: Text(g.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: p.text, fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: -0.3)),
          ),
          _Check(on: all, p: p, overlay: false),
        ]),
      ),
    );
  }

  // ─────────────────────────── TOP BAR (glass) ───────────────────────────
  Widget _topBar(_P p, bool selecting, double inset) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: _Glass(
        p: p,
        radius: 0,
        blur: 28,
        border: Border(bottom: BorderSide(color: p.border)),
        child: Padding(
          padding: EdgeInsets.only(top: inset),
          child: SizedBox(
            height: 56,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: selecting ? _selectBar(p) : _normalBar(p),
            ),
          ),
        ),
      ),
    );
  }

  Widget _normalBar(_P p) {
    return Row(key: const ValueKey('normal'), children: [
      const SizedBox(width: 20),
      Expanded(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Gallery',
                style: TextStyle(
                    color: p.text, fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
            Text('${_items.length}${_hasMore ? '+' : ''} photos',
                style: TextStyle(color: p.sub, fontSize: 12)),
          ],
        ),
      ),
      IconButton(
        onPressed: _toggleTheme,
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          transitionBuilder: (c, a) => RotationTransition(
            turns: Tween(begin: 0.75, end: 1.0).animate(a),
            child: FadeTransition(opacity: a, child: c),
          ),
          child: Icon(_light ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
              key: ValueKey(_light), color: p.text),
        ),
      ),
      PopupMenuButton<int>(
        icon: Icon(Icons.grid_view_rounded, color: p.text),
        tooltip: 'Grid size',
        color: p.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        onSelected: (v) => setState(() {
          _gridColumns = v;
          _layout = null;
        }),
        itemBuilder: (_) => [
          for (int i = 2; i <= 8; i++)
            PopupMenuItem(
              value: i,
              child: Text('$i Columns ${i == 2 ? '(Large)' : i == 8 ? '(Tiny)' : ''}',
                  style: TextStyle(
                      color: i == _gridColumns ? p.accent : p.text,
                      fontWeight: i == _gridColumns ? FontWeight.w700 : FontWeight.w500)),
            ),
        ],
      ),
      IconButton(
        icon: Icon(Icons.security_rounded, color: p.text),
        onPressed: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => const AlbumsScreen())),
      ),
      const SizedBox(width: 4),
    ]);
  }

  Widget _selectBar(_P p) {
    return Row(key: const ValueKey('select'), children: [
      IconButton(
        icon: Icon(Icons.close_rounded, color: p.text),
        onPressed: () => setState(_selected.clear),
      ),
      Expanded(
        child: Text('${_selected.length} selected',
            style: TextStyle(
                color: p.text, fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: -0.4)),
      ),
      IconButton(
        icon: Icon(Icons.select_all_rounded, color: p.text),
        onPressed: () => _sel(() => _selected.length == _items.length
            ? _selected.clear()
            : _selected.addAll(_items.map((e) => e.id))),
      ),
      // NEW: Share to / Copy to / Move to / Bin
      IconButton(
        tooltip: 'Share, copy, move, bin',
        icon: Icon(Icons.more_vert_rounded, color: p.text),
        onPressed: _openActions,
      ),
      IconButton(
        icon: const Icon(Icons.delete_rounded, color: Colors.redAccent),
        onPressed: _deleteSelectedFromPhone,
      ),
      IconButton(
        icon: Icon(Icons.lock_rounded, color: p.accent),
        onPressed: _moveSelectedToVault,
      ),
      const SizedBox(width: 4),
    ]);
  }

  // ─────────────────────────── YEAR BAR (glass) ───────────────────────────
  Widget _yearBar(_P p) {
    final years = _yearCounts.keys.toList()..sort((a, b) => b.compareTo(a));
    final selPerYear = <int, int>{};
    for (final id in _selected) {
      final y = _yearById[id];
      if (y != null) selPerYear[y] = (selPerYear[y] ?? 0) + 1;
    }
    return _Glass(
      key: const ValueKey('yearbar'),
      p: p,
      radius: 28,
      blur: 26,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(children: [
              Text('Select by year',
                  style: TextStyle(color: p.sub, fontSize: 12.5, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (_hasMore)
                SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: p.accent)),
            ]),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              itemCount: years.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final y = years[i];
                final total = _yearCounts[y] ?? 0;
                final on = total > 0 && (selPerYear[y] ?? 0) == total;
                return GestureDetector(
                  onTap: () => _toggleYear(y),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: on ? p.accent : p.glass,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: on ? Colors.transparent : p.border),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (on) ...[
                        const Icon(Icons.check_rounded, size: 16, color: Colors.white),
                        const SizedBox(width: 4),
                      ],
                      Text('$y',
                          style: TextStyle(
                              color: on ? Colors.white : p.text,
                              fontWeight: FontWeight.w700,
                              fontSize: 14)),
                      const SizedBox(width: 6),
                      Text('$total',
                          style: TextStyle(
                              color: on ? Colors.white70 : p.sub, fontSize: 12)),
                    ]),
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  PREVIEW SCREEN  (hero + swipe + pinch/double-tap zoom + drag-to-dismiss)
// ════════════════════════════════════════════════════════════════════
class _PreviewScreen extends StatefulWidget {
  const _PreviewScreen({
    required this.items,
    required this.initial,
    required this.thumbPx,
    required this.onChanged,
  });
  final List<AssetEntity> items;
  final int initial, thumbPx;
  final VoidCallback onChanged; // NEW

  @override
  State<_PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<_PreviewScreen> with SingleTickerProviderStateMixin {
  late final PageController _pc = PageController(initialPage: widget.initial);
  late int _cur = widget.initial;
  double _dragY = 0;
  bool _zoomed = false;

  late final AnimationController _snap;
  Animation<double> _snapAnim = const AlwaysStoppedAnimation(0.0);

  static const _bigSize = ThumbnailSize(1440, 1440);

  // NEW: preview is always dark
  final ActionColors _ac = _P.dark.actionColors;

  ImageProvider _big(AssetEntity a) =>
      AssetEntityImageProvider(a, isOriginal: false, thumbnailSize: _bigSize);
  ImageProvider _thumb(AssetEntity a) => AssetEntityImageProvider(a,
      isOriginal: false, thumbnailSize: ThumbnailSize.square(widget.thumbPx));

  @override
  void initState() {
    super.initState();
    _snap = AnimationController(vsync: this, duration: const Duration(milliseconds: 260))
      ..addListener(() => setState(() => _dragY = _snapAnim.value));
    WidgetsBinding.instance.addPostFrameCallback((_) => _precacheAround(_cur));
  }

  @override
  void dispose() {
    _snap.dispose();
    _pc.dispose();
    super.dispose();
  }

  void _precacheAround(int i) {
    for (final n in [i + 1, i - 1]) {
      if (n >= 0 && n < widget.items.length && mounted) {
        precacheImage(_big(widget.items[n]), context);
      }
    }
  }

  void _animateBack() {
    _snapAnim = Tween<double>(begin: _dragY, end: 0).animate(
        CurvedAnimation(parent: _snap, curve: Curves.easeOutCubic));
    _snap
      ..reset()
      ..forward();
  }

  // NEW
  void _showInfo() => showMetadataSheet(context, _ac, widget.items[_cur]);

  // NEW
  Future<void> _actions() async {
    final changed = await runGalleryAction(context, _ac, [widget.items[_cur]]);
    if (changed && mounted) {
      Navigator.of(context).pop();
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final n = widget.items.length;
    final cur = widget.items[_cur];
    final fade = (1 - _dragY.abs() / 320).clamp(0.0, 1.0);
    const dp = _P.dark;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(fit: StackFit.expand, children: [
        // glass backdrop = blurred version of the current photo
        Opacity(
          opacity: fade,
          child: Stack(fit: StackFit.expand, children: [
            const ColoredBox(color: Colors.black),
            RepaintBoundary(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                child: SizedBox.expand(
                  key: ValueKey(cur.id),
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 42, sigmaY: 42),
                    child: Image(image: _thumb(cur), fit: BoxFit.cover, gaplessPlayback: true),
                  ),
                ),
              ),
            ),
            ColoredBox(color: Colors.black.withValues(alpha: 0.5)),
          ]),
        ),

        // pager
        GestureDetector(
          onVerticalDragUpdate: _zoomed ? null : (d) => setState(() => _dragY += d.delta.dy),
          onVerticalDragEnd: _zoomed
              ? null
              : (d) {
                  final v = d.primaryVelocity ?? 0;
                  if (_dragY.abs() > 120 || v.abs() > 900) {
                    Navigator.of(context).pop();
                  } else {
                    _animateBack();
                  }
                },
          child: Transform.translate(
            offset: Offset(0, _dragY),
            child: Transform.scale(
              scale: 1 - (_dragY.abs() / 1600).clamp(0.0, 0.2),
              child: PageView.builder(
                controller: _pc,
                itemCount: n,
                physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
                onPageChanged: (i) {
                  setState(() => _cur = i);
                  _precacheAround(i);
                  HapticFeedback.selectionClick();
                },
                itemBuilder: (_, i) => _ZoomPage(
                  key: ValueKey(widget.items[i].id),
                  asset: widget.items[i],
                  thumbPx: widget.thumbPx,
                  onZoom: (z) {
                    if (i == _cur && z != _zoomed) setState(() => _zoomed = z);
                  },
                ),
              ),
            ),
          ),
        ),

        // top glass bar
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: _zoomed ? 0 : fade,
            child: IgnorePointer(
              ignoring: _zoomed,
              child: _Glass(
                p: dp,
                radius: 0,
                blur: 26,
                border: Border(bottom: BorderSide(color: dp.border)),
                child: Padding(
                  padding: EdgeInsets.only(top: mq.padding.top),
                  child: SizedBox(
                    height: 56,
                    child: Row(children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back_ios_new_rounded,
                            color: Colors.white, size: 20),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(DateFormat('d MMM yyyy').format(cur.createDateTime),
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                            Text('${_cur + 1} / $n',
                                style: const TextStyle(color: Colors.white60, fontSize: 12)),
                          ],
                        ),
                      ),
                      // NEW: metadata + actions
                      IconButton(
                        tooltip: 'Details',
                        icon: const Icon(Icons.info_outline_rounded, color: Colors.white),
                        onPressed: _showInfo,
                      ),
                      IconButton(
                        tooltip: 'Share, copy, move, bin',
                        icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
                        onPressed: _actions,
                      ),
                      const SizedBox(width: 4),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),

        // bottom glass info pill (tap → full details)
        Positioned(
          left: 16,
          right: 16,
          bottom: mq.padding.bottom + 14,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: _zoomed ? 0 : fade,
            child: GestureDetector(
              onTap: _showInfo,
              child: _Glass(
                p: dp,
                radius: 22,
                blur: 26,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  child: Row(children: [
                    const Icon(Icons.schedule_rounded, color: Colors.white70, size: 18),
                    const SizedBox(width: 8),
                    Text(DateFormat('h:mm a').format(cur.createDateTime),
                        style: const TextStyle(color: Colors.white, fontSize: 14)),
                    const Spacer(),
                    Text('${cur.width} × ${cur.height}',
                        style: const TextStyle(color: Colors.white60, fontSize: 13)),
                    const SizedBox(width: 8),
                    const Icon(Icons.keyboard_arrow_up_rounded, color: Colors.white60, size: 20),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

// ── single zoomable page ──
class _ZoomPage extends StatefulWidget {
  const _ZoomPage({super.key, required this.asset, required this.thumbPx, required this.onZoom});
  final AssetEntity asset;
  final int thumbPx;
  final ValueChanged<bool> onZoom;

  @override
  State<_ZoomPage> createState() => _ZoomPageState();
}

class _ZoomPageState extends State<_ZoomPage> with SingleTickerProviderStateMixin {
  final _tc = TransformationController();
  late final AnimationController _anim;
  Matrix4Tween? _tween;
  bool _zoomed = false, _orig = false;
  Offset _tap = Offset.zero;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 300))
      ..addListener(() {
        final t = _tween;
        if (t == null) return;
        _tc.value = t.transform(Curves.easeOutCubic.transform(_anim.value));
        _report();
      });
  }

  @override
  void dispose() {
    _anim.dispose();
    _tc.dispose();
    super.dispose();
  }

  void _report() {
    final s = _tc.value.getMaxScaleOnAxis();
    final z = s > 1.03;
    if (z != _zoomed) {
      setState(() => _zoomed = z);
      widget.onZoom(z);
    }
    if (!_orig && s > 1.4) setState(() => _orig = true); // load full-res only when zooming
  }

  void _doubleTap() {
    final from = _tc.value;
    final zoomedNow = from.getMaxScaleOnAxis() > 1.05;
    const s = 2.6;
    final to = zoomedNow
        ? Matrix4.identity()
        : Matrix4(s, 0, 0, 0, 0, s, 0, 0, 0, 0, 1, 0, -_tap.dx * (s - 1), -_tap.dy * (s - 1), 0, 1);
    _tween = Matrix4Tween(begin: from, end: to);
    _anim
      ..reset()
      ..forward();
  }

  Widget _fade(ImageProvider p) => Image(
        image: p,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        frameBuilder: (c, child, frame, sync) => AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: const Duration(milliseconds: 220),
            child: child),
      );

  @override
  Widget build(BuildContext context) {
    final a = widget.asset;
    final ar = (a.orientatedWidth > 0 && a.orientatedHeight > 0)
        ? a.orientatedWidth / a.orientatedHeight
        : 1.0;
    final thumb = AssetEntityImageProvider(a,
        isOriginal: false, thumbnailSize: ThumbnailSize.square(widget.thumbPx));
    final big = AssetEntityImageProvider(a,
        isOriginal: false, thumbnailSize: const ThumbnailSize(1440, 1440));

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTapDown: (d) => _tap = d.localPosition,
      onDoubleTap: _doubleTap,
      child: InteractiveViewer(
        transformationController: _tc,
        minScale: 1,
        maxScale: 6,
        onInteractionUpdate: (_) => _report(),
        onInteractionEnd: (_) => _report(),
        child: LayoutBuilder(builder: (ctx, c) {
          double w = c.maxWidth, h = w / ar;
          if (h > c.maxHeight) {
            h = c.maxHeight;
            w = h * ar;
          }
          return Center(
            child: SizedBox(
              width: w,
              height: h,
              child: Hero(
                tag: 'photo_${a.id}',
                flightShuttleBuilder: _shuttle(thumb),
                child: Stack(fit: StackFit.expand, children: [
                  Image(image: thumb, fit: BoxFit.cover, gaplessPlayback: true),
                  _fade(big),
                  if (_orig)
                    _fade(AssetEntityImageProvider(a, isOriginal: true)),
                ]),
              ),
            ),
          );
        }),
      ),
    );
  }
}
