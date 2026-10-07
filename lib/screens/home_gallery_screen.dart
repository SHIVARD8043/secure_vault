import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../core/vault_service.dart';
import '../db/database_helper.dart';
import '../db/vault_queries.dart';
import 'albums_screen.dart';
import 'home_preview_screen.dart';
import 'video_loop_preview.dart';
import 'video_player_screen.dart';
import 'package:provider/provider.dart';
import '../core/theme_provider.dart';

// ════════════════════════════════════════════════════════════════════
//  PALETTE, GLASS WIDGET & SHARED BUTTONS
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

  static const light = _P(
    bg: Color(0xFFEDEFF6), bg2: Color(0xFFFFFFFF), text: Color(0xFF12141C), sub: Color(0xFF6B7285),
    glass: Color(0x99FFFFFF), border: Color(0xE6FFFFFF), bar: Color(0xB8FFFFFF), accent: Color(0xFF3D5AFE), surface: Color(0xFFFFFFFF),
  );

  static _P mix(double t) => _P(
        bg: Color.lerp(dark.bg, light.bg, t)!, bg2: Color.lerp(dark.bg2, light.bg2, t)!,
        text: Color.lerp(dark.text, light.text, t)!, sub: Color.lerp(dark.sub, light.sub, t)!,
        glass: Color.lerp(dark.glass, light.glass, t)!, border: Color.lerp(dark.border, light.border, t)!,
        bar: Color.lerp(dark.bar, light.bar, t)!, accent: Color.lerp(dark.accent, light.accent, t)!,
        surface: Color.lerp(dark.surface, light.surface, t)!,
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

/// Press-scale wrapper with haptic feedback.
class _Press extends StatefulWidget {
  const _Press({required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;
  @override
  State<_Press> createState() => _PressState();
}

class _PressState extends State<_Press> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) {
        setState(() => _down = false);
        HapticFeedback.selectionClick();
        widget.onTap();
      },
      onTapCancel: () => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? 0.88 : 1, duration: const Duration(milliseconds: 110), curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

class _DockBtn extends StatelessWidget {
  const _DockBtn({required this.icon, required this.label, required this.color, required this.p, required this.onTap});
  final IconData icon;
  final String label;
  final Color color;
  final _P p;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _Press(
      onTap: onTap,
      child: SizedBox(
        width: 58,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 46, height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [color.withValues(alpha: 0.30), color.withValues(alpha: 0.10)],
              ),
              border: Border.all(color: color.withValues(alpha: 0.35)),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(height: 5),
          Text(label, style: TextStyle(color: p.text.withValues(alpha: 0.85), fontSize: 10.5, fontWeight: FontWeight.w600, letterSpacing: 0.2)),
        ]),
      ),
    );
  }
}

/// Floating vertical glass dock on the right side (shown while selecting).
class _Dock extends StatelessWidget {
  const _Dock({super.key, required this.p, required this.count, required this.onShare, required this.onCopy, required this.onMove, required this.onDelete});
  final _P p;
  final int count;
  final VoidCallback onShare, onCopy, onMove, onDelete;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 28, offset: const Offset(-4, 8))],
      ),
      child: _Glass(
        p: p, radius: 32, blur: 30,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 5),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: LinearGradient(colors: [p.accent, p.accent.withValues(alpha: 0.7)]),
              ),
              child: Text('$count', style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 12),
            _DockBtn(icon: Icons.ios_share_rounded, label: 'Share', color: p.accent, p: p, onTap: onShare),
            const SizedBox(height: 12),
            _DockBtn(icon: Icons.copy_rounded, label: 'Copy', color: p.accent, p: p, onTap: onCopy),
            const SizedBox(height: 12),
            _DockBtn(icon: Icons.drive_file_move_rounded, label: 'Move', color: p.accent, p: p, onTap: onMove),
            const SizedBox(height: 10),
            Container(width: 28, height: 1, color: p.border),
            const SizedBox(height: 10),
            _DockBtn(icon: Icons.delete_outline_rounded, label: 'Delete', color: Colors.redAccent, p: p, onTap: onDelete),
          ]),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  SMALL MODELS
// ════════════════════════════════════════════════════════════════════
class _Group {
  _Group(this.label, this.start, this.year);
  final String label;
  final int start;
  final int year;
  int count = 1;
}

class _Row {
  const _Row(this.header, this.group, this.start, this.count, this.top, this.height);
  final bool header;
  final int group;
  final int start;
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

class _Check extends StatelessWidget {
  const _Check({super.key, required this.on, required this.p, this.overlay = true});
  final bool on, overlay;
  final _P p;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: 24, height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? p.accent : (overlay ? Colors.black.withValues(alpha: 0.28) : Colors.transparent),
        border: on ? null : Border.all(color: overlay ? Colors.white : p.sub.withValues(alpha: 0.6), width: 1.6),
      ),
      child: AnimatedScale(
        scale: on ? 1 : 0, duration: const Duration(milliseconds: 220), curve: Curves.easeOutBack,
        child: const Icon(Icons.check_rounded, size: 16, color: Colors.white),
      ),
    );
  }
}

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

String _fmtDur(Duration d) {
  final h = d.inHours, m = d.inMinutes.remainder(60), sec = d.inSeconds.remainder(60);
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

class _Tile extends StatelessWidget {
  const _Tile({super.key, required this.asset, required this.px, required this.selected, required this.selecting, required this.p, required this.live});
  final AssetEntity asset;
  final int px;
  final bool selected, selecting;
  final _P p;
  /// ids of video tiles that are allowed to run the 5s loop preview right now.
  final ValueListenable<Set<String>> live;

  @override
  Widget build(BuildContext context) {
    final provider = AssetEntityImageProvider(asset, isOriginal: false, thumbnailSize: ThumbnailSize.square(px));
    final isVideo = asset.type == AssetType.video;

    final framed = DecoratedBox(
      decoration: BoxDecoration(color: p.glass, borderRadius: BorderRadius.circular(11), border: Border.all(color: p.border)),
      child: Padding(
        padding: const EdgeInsets.all(1.5),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9.5),
          child: Stack(fit: StackFit.expand, children: [
            Image(
              image: provider, fit: BoxFit.cover, gaplessPlayback: true,
              frameBuilder: (c, child, frame, sync) => sync ? child : AnimatedOpacity(
                      opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 220), child: child),
            ),
            // 5s muted loop - mounted only for the few tiles chosen by the screen (see _updateLive)
            if (isVideo)
              ValueListenableBuilder<Set<String>>(
                valueListenable: live,
                builder: (_, ids, __) => ids.contains(asset.id)
                    ? VideoLoopPreview(key: ValueKey('loop_${asset.id}'), loadFile: () => asset.originFile)
                    : const SizedBox.shrink(),
              ),
            const IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.center, colors: [Color(0x26FFFFFF), Color(0x00FFFFFF)])))),
            if (isVideo)
              Positioned(
                right: 5, bottom: 5,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(8)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 13),
                      const SizedBox(width: 2),
                      Text(_fmtDur(asset.videoDuration), style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
              ),
            AnimatedContainer(duration: const Duration(milliseconds: 180), color: selected ? p.accent.withValues(alpha: 0.22) : Colors.transparent),
          ]),
        ),
      ),
    );

    return RepaintBoundary(
      child: Stack(fit: StackFit.expand, children: [
        AnimatedScale(
          scale: selected ? 0.86 : 1, duration: const Duration(milliseconds: 200), curve: Curves.easeOutCubic,
          // videos open in VideoPlayerScreen (no Hero target), so Hero only for images
          child: isVideo ? framed : Hero(tag: 'photo_${asset.id}', flightShuttleBuilder: _shuttle(provider), child: framed),
        ),
        if (selecting) Positioned(top: 7, left: 7, child: _Check(on: selected, p: p)),
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

class _HomeGalleryScreenState extends State<HomeGalleryScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _pageSize = 120;
  static const _hPad = 4.0, _gap = 3.0, _headerH = 58.0;

  final _scroll = ScrollController();
  final List<AssetEntity> _items = [];
  final List<_Group> _groups = [];
  final Set<String> _selected = {};

  AssetPathEntity? _album;
  bool _hasMore = true, _loading = false, _ready = false;
  int _gen = 0;
  int _gridColumns = 3;
  _Layout? _layout;
  Future<void>? _loadAllFuture;

  late final AnimationController _themeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 450));
  bool _light = false;
  _P get _pal => _P.mix(Curves.easeInOut.transform(_themeCtrl.value));

  bool _dragActive = false, _dragSelect = true;
  int _anchor = 0, _lastIdx = -1;
  Set<String> _dragBase = {};
  Offset? _lastPointer;
  Timer? _autoTimer;
  double _topPad = 0, _viewH = 0, _gw = 0;

  // ── video loop previews: only a few tiles play, and only when scrolling has settled ──
  static const _maxLive = 4;
  final ValueNotifier<Set<String>> _live = ValueNotifier(const <String>{});
  Timer? _idleTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(() {
      if (_scroll.hasClients && _scroll.position.pixels > _scroll.position.maxScrollExtent - 1200) _loadMore();
    });
    _reload();

    // 👈 యాప్ ఓపెన్ అవ్వగానే, సేవ్ అయిన థీమ్ లోకి మారడానికి
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final isDark = context.read<ThemeProvider>().isDark;
      setState(() {
        _light = !isDark;
        _themeCtrl.value = _light ? 1.0 : 0.0;
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _idleTimer?.cancel();
    _live.dispose();
    _autoTimer?.cancel();
    _themeCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) { _scheduleLive(); } else { _stopLive(); }
  }

  void _stopLive() {
    _idleTimer?.cancel();
    if (_live.value.isNotEmpty) _live.value = const <String>{};
  }

  void _scheduleLive([int ms = 400]) {
    _idleTimer?.cancel();
    _idleTimer = Timer(Duration(milliseconds: ms), _updateLive);
  }

  bool _onScrollNote(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is ScrollStartNotification || n is ScrollUpdateNotification) {
      if (_live.value.isNotEmpty) _live.value = const <String>{}; // free decoders while moving
      _scheduleLive(350); // debounce: fires ~350ms after the last scroll movement
    }
    return false;
  }

  /// Picks up to _maxLive visible videos (closest to viewport centre) for loop preview.
  void _updateLive() {
    final L = _layout;
    if (!mounted || L == null || L.rows.isEmpty || !_scroll.hasClients || _viewH == 0) return;
    final y0 = _scroll.offset, y1 = y0 + _viewH - _topPad, mid = (y0 + y1) / 2;
    var lo = 0, hi = L.rows.length - 1;
    while (lo < hi) {
      final m = (lo + hi) >> 1;
      if (L.rows[m].top + L.rows[m].height <= y0) lo = m + 1; else hi = m;
    }
    final cand = <(double, String)>[];
    for (var i = lo; i < L.rows.length && L.rows[i].top < y1; i++) {
      final r = L.rows[i];
      if (r.header) continue;
      final dist = ((r.top + r.height / 2) - mid).abs();
      for (var c = 0; c < r.count; c++) {
        final a = _items[r.start + c];
        if (a.type == AssetType.video) cand.add((dist, a.id));
      }
    }
    cand.sort((a, b) => a.$1.compareTo(b.$1));
    final next = cand.take(_maxLive).map((e) => e.$2).toSet();
    if (!setEquals(next, _live.value)) _live.value = next;
  }

  Future<void> _reload() async {
    final gen = ++_gen;
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.isAuth) { PhotoManager.openSetting(); return; }
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.image | RequestType.video, onlyAll: true,
      filterOption: FilterOptionGroup(orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)]),
    );
    if (!mounted || gen != _gen) return;
    if (albums.isEmpty) { setState(() => _ready = true); return; }
    _album = albums.first;
    final want = math.max(_pageSize, _items.length);
    final first = await _album!.getAssetListRange(start: 0, end: want);
    if (!mounted || gen != _gen) return;
    setState(() {
      _items..clear()..addAll(first);
      _hasMore = first.length == want;
      _loadAllFuture = null;
      _loading = false;
      _regroup();
      _ready = true;
    });
    _scheduleLive(600);
  }

  Future<void> _loadMore({int size = _pageSize}) async {
    if (_loading || !_hasMore || _album == null) return;
    _loading = true;
    final gen = _gen;
    try {
      final batch = await _album!.getAssetListRange(start: _items.length, end: _items.length + size);
      if (!mounted || gen != _gen) return;
      setState(() {
        _items.addAll(batch);
        if (batch.length < size) _hasMore = false;
        _regroup();
      });
    } finally { _loading = false; }
  }

  Future<void> _loadAll() async {
    final gen = _gen;
    while (mounted && gen == _gen && _hasMore && _album != null) {
      if (_loading) { await Future.delayed(const Duration(milliseconds: 40)); continue; }
      await _loadMore(size: 1000);
    }
  }

  void _regroup() {
    _layout = null; _groups.clear();
    final now = DateTime.now(), today = DateTime(now.year, now.month, now.day), yesterday = today.subtract(const Duration(days: 1));
    String? lastKey;
    for (var i = 0; i < _items.length; i++) {
      final a = _items[i], d = a.createDateTime, day = DateTime(d.year, d.month, d.day);
      final String key = day == today ? 'T' : day == yesterday ? 'Y' : d.year == now.year ? 'd${day.millisecondsSinceEpoch}' : 'm${d.year}-${d.month}';
      if (key != lastKey) {
        final label = key == 'T' ? "ఈరోజు (Today)" : key == 'Y' ? "నిన్న (Yesterday)" : d.year == now.year ? DateFormat('EEE, MMM d').format(d) : DateFormat('MMMM yyyy').format(d);
        _groups.add(_Group(label, i, d.year));
        lastKey = key;
      } else { _groups.last.count++; }
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

  void _sel(VoidCallback f) { setState(f); if (_selected.isNotEmpty) _loadAllFuture ??= _loadAll(); }
  void _toggle(AssetEntity a) => _sel(() => _selected.contains(a.id) ? _selected.remove(a.id) : _selected.add(a.id));
  void _toggleGroup(int gi) {
    final g = _groups[gi], ids = _items.sublist(g.start, g.start + g.count).map((e) => e.id).toList(), all = ids.every(_selected.contains);
    HapticFeedback.selectionClick();
    _sel(() => all ? _selected.removeAll(ids) : _selected.addAll(ids));
  }

  (_Row, int)? _hit(Offset local) {
    final L = _layout;
    if (L == null || !_scroll.hasClients || L.rows.isEmpty) return null;
    final y = _scroll.offset + local.dy - _topPad;
    if (y < 0 || y > L.total) return null;
    var lo = 0, hi = L.rows.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (L.rows[mid].top <= y) lo = mid; else hi = mid - 1;
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
    if (row.header) { if (_selected.isNotEmpty || d.localPosition.dx > _gw - 80) _toggleGroup(row.group); return; }
    if (_selected.isNotEmpty) _toggle(_items[idx]); else _openPreview(idx);
  }

  void _dragStart(LongPressStartDetails d) {
    final hit = _hit(d.localPosition);
    if (hit == null || hit.$1.header) return;
    final idx = hit.$2, id = _items[idx].id;
    _dragActive = true; _anchor = idx; _lastIdx = idx; _dragSelect = !_selected.contains(id); _dragBase = {..._selected};
    _lastPointer = d.localPosition; HapticFeedback.mediumImpact();
    _sel(() => _dragSelect ? _selected.add(id) : _selected.remove(id));
    _autoTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) => _autoScrollTick());
  }

  void _dragMove(LongPressMoveUpdateDetails d) { if (!_dragActive) return; _lastPointer = d.localPosition; _applyDrag(); }
  void _dragEnd() { _dragActive = false; _autoTimer?.cancel(); _autoTimer = null; }
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
    for (var i = lo; i <= hi; i++) _dragSelect ? next.add(_items[i].id) : next.remove(_items[i].id);
    HapticFeedback.selectionClick();
    setState(() { _selected.clear(); _selected.addAll(next); });
  }

  void _autoScrollTick() {
    final p = _lastPointer;
    if (!_dragActive || p == null || !_scroll.hasClients) return;
    double v = 0;
    final up = (_topPad + 50 - p.dy) / 90, down = (p.dy - (_viewH - 130)) / 90;
    if (up > 0) v = -up.clamp(0.0, 1.0) * 26;
    if (down > 0) v = down.clamp(0.0, 1.0) * 26;
    if (v == 0) return;
    final pos = _scroll.position, target = (pos.pixels + v).clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if (target != pos.pixels) { _scroll.jumpTo(target); _lastIdx = -1; _applyDrag(); }
  }

  Future<void> _openPreview(int idx) async {
    final asset = _items[idx];
    _stopLive(); // release decoders before another screen takes over
    if (asset.type == AssetType.video) {
      final f = await asset.originFile;
      if (f == null || !mounted) { _scheduleLive(); return; }
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => VideoPlayerScreen(file: f, title: asset.title)));
    } else {
      // HomePreviewScreen is image-only, so swipe through images only
      final imgs = _items.where((e) => e.type != AssetType.video).toList();
      final start = imgs.indexWhere((e) => e.id == asset.id);
      final px = _layout?.thumbPx ?? 250;
      await Navigator.of(context).push(PageRouteBuilder<void>(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 420),
        reverseTransitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (_, __, ___) => HomePreviewScreen(items: imgs, initial: start < 0 ? 0 : start, thumbPx: px),
        transitionsBuilder: (_, a, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: a, curve: Curves.easeOutCubic),
          child: child,
        ),
      ));
    }
    if (mounted) _scheduleLive();
  }

  // ─────────────────────────── ACTIONS ───────────────────────────
  Future<String?> _showAlbumPicker(String title) async {
    final albums = (await DatabaseHelper.instance.fetchAlbums()).map((e) => e['albumName'] as String).toList();
    final ctrl = TextEditingController();
    final p = _pal;
    if (!mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        title: Text(title, style: TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.w700)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: ctrl, style: TextStyle(color: p.text), decoration: InputDecoration(hintText: 'కొత్త ఆల్బమ్ పేరు', hintStyle: TextStyle(color: p.sub))),
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final a in albums) ActionChip(backgroundColor: p.bg2, side: BorderSide(color: p.border), label: Text(a, style: TextStyle(color: p.text)), onPressed: () => Navigator.pop(ctx, a)),
          ]),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim().isEmpty ? 'My_Photos' : ctrl.text.trim()), child: const Text('Select')),
        ],
      ),
    );
  }

  Future<void> _shareSelected() async {
    final chosen = _items.where((a) => _selected.contains(a.id)).toList();
    if (chosen.isEmpty) return;

    final files = <XFile>[];
    for (final a in chosen) {
      final file = await a.originFile;
      if (file != null && await file.exists()) {
        files.add(XFile(file.path));
      }
    }

    if (files.isNotEmpty) {
      await Share.shareXFiles(files);
      if (!mounted) return;
      setState(() => _selected.clear());
    }
  }

  Future<void> _copySelectedToVault() async {
    final chosen = _items.where((a) => _selected.contains(a.id)).toList();
    if (chosen.isEmpty) return;
    final targetAlbum = await _showAlbumPicker('కాపీ టు వాల్ట్ (Copy)');
    if (targetAlbum == null || !mounted) return;

    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    final vault = VaultService();
    int successCount = 0;

    for (final a in chosen) {
      if (await vault.hideAsset(a, targetAlbum)) successCount++;
    }

    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$successCount/${chosen.length} ఫోటోలు $targetAlbum లోకి కాపీ అయ్యాయి 📄')));
    setState(_selected.clear);
  }

  Future<void> _moveSelectedToVault() async {
    final chosen = _items.where((a) => _selected.contains(a.id)).toList();
    if (chosen.isEmpty) return;
    final targetAlbum = await _showAlbumPicker('వాల్ట్ లోకి మార్చు (Move)');
    if (targetAlbum == null || !mounted) return;

    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    final vault = VaultService();
    int successCount = 0;

    for (final a in chosen) {
      if (await vault.hideAsset(a, targetAlbum)) {
        successCount++;
        // 👈 ఎలాంటి పర్మిషన్ డైలాగ్ అడగకుండా సైలెంట్ గా డిలీట్ చేస్తున్నాం
        try {
          final file = await a.originFile;
          if (file != null && await file.exists()) {
            await file.delete(); 
          }
        } catch (e) { 
          debugPrint('Silent delete failed: $e'); 
        }
      }
    }
    
    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$successCount/${chosen.length} ఫోటోలు $targetAlbum లో లాక్ అయ్యాయి 🔒')));
    setState(_selected.clear);
    await _reload();
  }

  Future<void> _binSelected() async {
    final chosen = _items.where((a) => _selected.contains(a.id)).toList();
    if (chosen.isEmpty) return;

    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    final vault = VaultService();
    int successCount = 0;

    for (final a in chosen) {
      // trash: true అని పంపితే నేరుగా వాల్ట్ బిన్ లోకి వెళ్తుంది
      if (await vault.hideAsset(a, 'My_Photos', trash: true)) {
        successCount++;
        // 👈 ఇక్కడ కూడా పర్మిషన్ డైలాగ్ లేకుండా డైరెక్ట్ గా ఫైల్ ని లేపేస్తున్నాం 
        try {
          final file = await a.originFile;
          if (file != null && await file.exists()) {
            await file.delete(); 
          }
        } catch (e) { 
          debugPrint('Silent delete failed: $e'); 
        }
      }
    }

    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$successCount ఫోటోలు Vault Bin లోకి వెళ్ళాయి 🗑️')));
    setState(_selected.clear);
    await _reload();
  }

  void _toggleTheme() {
    HapticFeedback.lightImpact();
    
    // 1. ThemeProvider ని పిలిచి డేటాబేస్ (SharedPreferences) లో సేవ్ చేస్తున్నాం
    context.read<ThemeProvider>().toggleTheme();

    // 2. దాన్ని బట్టి మన హోమ్ స్క్రీన్ యానిమేషన్ రన్ చేస్తున్నాం
    setState(() => _light = !_light);
    _light ? _themeCtrl.forward() : _themeCtrl.reverse();
  }

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
          value: SystemUiOverlayStyle(statusBarColor: Colors.transparent, statusBarIconBrightness: _light ? Brightness.dark : Brightness.light, statusBarBrightness: _light ? Brightness.light : Brightness.dark),
          child: PopScope(
            canPop: !selecting,
            onPopInvokedWithResult: (didPop, _) { if (!didPop) setState(_selected.clear); },
            child: Scaffold(
              backgroundColor: p.bg,
              body: DecoratedBox(
                decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [p.bg, p.bg2])),
                child: Stack(children: [
                  Positioned.fill(child: _body(p, selecting, mq)),
                  _topBar(p, selecting, mq.padding.top),

                  // ─── RIGHT SIDE DOCK ( Share, Copy, Move, Delete ) ───
                  Positioned(
                    right: 10, top: _topPad, bottom: mq.padding.bottom + 24,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 280), switchInCurve: Curves.easeOutCubic,
                        transitionBuilder: (c, a) => FadeTransition(opacity: a, child: SlideTransition(position: Tween(begin: const Offset(0.8, 0), end: Offset.zero).animate(a), child: c)),
                        child: selecting
                            ? _Dock(
                                key: const ValueKey('home_dock'),
                                p: p, count: _selected.length,
                                onShare: _shareSelected, onCopy: _copySelectedToVault,
                                onMove: _moveSelectedToVault, onDelete: _binSelected,
                              )
                            : const SizedBox.shrink(),
                      ),
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
    if (_items.isEmpty) return Center(child: Text('No photos', style: TextStyle(color: p.sub, fontSize: 16)));
    return LayoutBuilder(builder: (ctx, c) {
      _viewH = c.maxHeight; _gw = c.maxWidth;
      final L = _layoutFor(c.maxWidth, mq.devicePixelRatio);
      return GestureDetector(
        behavior: HitTestBehavior.translucent, onTapUp: _tapUp, onLongPressStart: _dragStart, onLongPressMoveUpdate: _dragMove, onLongPressEnd: (_) => _dragEnd(), onLongPressCancel: _dragEnd,
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScrollNote,
          child: CustomScrollView(
          controller: _scroll, physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()), cacheExtent: 1200,
          slivers: [
            SliverPadding(
              padding: EdgeInsets.only(top: _topPad, bottom: 40 + mq.padding.bottom),
              sliver: SliverVariedExtentList(
                itemExtentBuilder: (i, _) => L.rows[i].height,
                delegate: SliverChildBuilderDelegate((ctx, i) => _rowWidget(L.rows[i], L, p, selecting), childCount: L.rows.length, addAutomaticKeepAlives: false),
              ),
            ),
          ],
        ),
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
          SizedBox(width: L.cell, height: L.cell, child: _Tile(key: ValueKey(_items[r.start + c].id), asset: _items[r.start + c], px: L.thumbPx, selected: _selected.contains(_items[r.start + c].id), selecting: selecting, p: p, live: _live)),
        ],
      ]),
    );
  }

  Widget _header(_Row r, _P p, bool selecting) {
    final g = _groups[r.group];
    var all = false;
    if (selecting) {
      all = true;
      for (var i = g.start; i < g.start + g.count; i++) { if (!_selected.contains(_items[i].id)) { all = false; break; } }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
      child: Align(alignment: Alignment.bottomLeft, child: Row(children: [
          Expanded(child: Text(g.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: -0.3))),
          _Check(on: all, p: p, overlay: false),
      ])),
    );
  }

  Widget _topBar(_P p, bool selecting, double inset) {
    return Positioned(
      top: 0, left: 0, right: 0,
      child: _Glass(
        p: p, radius: 0, blur: 28, border: Border(bottom: BorderSide(color: p.border)),
        child: Padding(
          padding: EdgeInsets.only(top: inset),
          child: SizedBox(
            height: 56,
            child: AnimatedSwitcher(duration: const Duration(milliseconds: 220), child: selecting ? _selectBar(p) : _normalBar(p)),
          ),
        ),
      ),
    );
  }

  Widget _normalBar(_P p) {
    return Row(key: const ValueKey('normal'), children: [
      const SizedBox(width: 20),
      Expanded(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Gallery', style: TextStyle(color: p.text, fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
            Text('${_items.length}${_hasMore ? '+' : ''} items', style: TextStyle(color: p.sub, fontSize: 12)),
        ]),
      ),
      IconButton(
        onPressed: _toggleTheme,
        icon: AnimatedSwitcher(duration: const Duration(milliseconds: 300), transitionBuilder: (c, a) => RotationTransition(turns: Tween(begin: 0.75, end: 1.0).animate(a), child: FadeTransition(opacity: a, child: c)), child: Icon(_light ? Icons.dark_mode_rounded : Icons.light_mode_rounded, key: ValueKey(_light), color: p.text)),
      ),
      PopupMenuButton<int>(
        icon: Icon(Icons.grid_view_rounded, color: p.text), tooltip: 'Grid size', color: p.surface, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        onSelected: (v) { setState(() { _gridColumns = v; _layout = null; }); _stopLive(); _scheduleLive(600); },
        itemBuilder: (_) => [for (int i = 2; i <= 8; i++) PopupMenuItem(value: i, child: Text('$i Columns ${i == 2 ? '(Large)' : i == 8 ? '(Tiny)' : ''}', style: TextStyle(color: i == _gridColumns ? p.accent : p.text, fontWeight: i == _gridColumns ? FontWeight.w700 : FontWeight.w500)))],
      ),
      IconButton(icon: Icon(Icons.security_rounded, color: p.text), onPressed: () async { _stopLive(); await Navigator.push(context, MaterialPageRoute(builder: (_) => const AlbumsScreen())); _scheduleLive(); }),
      const SizedBox(width: 4),
    ]);
  }

  Widget _selectBar(_P p) {
    return Row(key: const ValueKey('select'), children: [
      IconButton(icon: Icon(Icons.close_rounded, color: p.text), onPressed: () => setState(_selected.clear)),
      Expanded(child: Text('${_selected.length} selected', style: TextStyle(color: p.text, fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: -0.4))),
      IconButton(icon: Icon(Icons.select_all_rounded, color: p.text), onPressed: () => _sel(() => _selected.length == _items.length ? _selected.clear() : _selected.addAll(_items.map((e) => e.id)))),
      const SizedBox(width: 4),
    ]);
  }
}