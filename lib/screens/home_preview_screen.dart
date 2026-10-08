import 'dart:io';
import 'dart:ui' show ImageFilter, lerpDouble;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:provider/provider.dart';
import 'package:image_cropper/image_cropper.dart';
import '../core/theme_provider.dart';

// ─── GLASS WIDGET ───
class _Glass extends StatelessWidget {
  const _Glass({
    required this.p, required this.child, this.radius = 24, this.blur = 22, this.border,
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

HeroFlightShuttleBuilder _shuttle(ImageProvider img) {
  return (ctx, anim, dir, fromCtx, toCtx) => AnimatedBuilder(
        animation: anim,
        builder: (_, __) {
          final t = dir == HeroFlightDirection.push ? anim.value : 1 - anim.value;
          final r = lerpDouble(11, 0, Curves.easeOut.transform(t.clamp(0.0, 1.0)))!;
          return ClipRRect(
            borderRadius: BorderRadius.circular(r),
            child: Image(image: img, fit: BoxFit.contain, gaplessPlayback: true), // 👈 మార్పు: BoxFit.cover నుండి contain కి మార్చాం
          );
        },
      );
}

// ─── METADATA HELPERS ───
String _fmtSize(int b) {
  if (b <= 0) return '-';
  const u = ['B', 'KB', 'MB', 'GB'];
  var v = b.toDouble(), i = 0;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${u[i]}';
}

Future<Map<String, String>> _loadMeta(AssetEntity asset) async {
  final out = <String, String>{};
  out['Name'] = asset.title ?? 'Unknown';
  out['Created'] = DateFormat('EEE, d MMM yyyy • h:mm a').format(asset.createDateTime);
  out['Modified'] = DateFormat('d MMM yyyy • h:mm a').format(asset.modifiedDateTime);
  
  final f = await asset.originFile;
  if (f != null && await f.exists()) {
    final st = await f.stat();
    out['Size'] = _fmtSize(st.size);
    out['Path'] = f.path;
    out['Type'] = f.path.contains('.') ? f.path.split('.').last.toUpperCase() : '-';
  } else {
    out['Size'] = 'File missing';
    out['Path'] = '-';
    out['Type'] = '-';
  }
  
  out['Resolution'] = '${asset.width} × ${asset.height}  (${(asset.width * asset.height / 1e6).toStringAsFixed(1)} MP)';
  return out;
}

Future<void> _showMeta(BuildContext context, AppPalette p, AssetEntity item) {
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

// ─── HOME PREVIEW SCREEN ───
class HomePreviewScreen extends StatefulWidget {
  const HomePreviewScreen({
    super.key,
    required this.items,
    required this.initial,
    required this.thumbPx,
  });
  final List<AssetEntity> items;
  final int initial, thumbPx;

  @override
  State<HomePreviewScreen> createState() => _HomePreviewScreenState();
}

class _HomePreviewScreenState extends State<HomePreviewScreen> with SingleTickerProviderStateMixin {
  late final PageController _pc = PageController(initialPage: widget.initial);
  late int _cur = widget.initial;
  double _dragY = 0;
  bool _zoomed = false;
  bool _chrome = false;

  late final AnimationController _snap;
  Animation<double> _snapAnim = const AlwaysStoppedAnimation(0.0);

  static const _bigSize = ThumbnailSize(1440, 1440);

  ImageProvider _big(AssetEntity a) => AssetEntityImageProvider(a, isOriginal: false, thumbnailSize: _bigSize);
  ImageProvider _thumb(AssetEntity a) => AssetEntityImageProvider(a, isOriginal: false, thumbnailSize: ThumbnailSize.square(widget.thumbPx));

  @override
  void initState() {
    super.initState();
    _snap = AnimationController(vsync: this, duration: const Duration(milliseconds: 260))
      ..addListener(() => setState(() => _dragY = _snapAnim.value));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addPostFrameCallback((_) => _precacheAround(_cur));
  }

  @override
  void dispose() {
    _showSystemUi();
    _snap.dispose();
    _pc.dispose();
    super.dispose();
  }

  void _showSystemUi() => SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  void _toggleChrome() {
    setState(() => _chrome = !_chrome);
    SystemChrome.setEnabledSystemUIMode(_chrome ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky);
  }

  void _precacheAround(int i) {
    for (final n in [i + 1, i - 1]) {
      if (n >= 0 && n < widget.items.length && mounted) {
        precacheImage(_big(widget.items[n]), context);
      }
    }
  }

  void _animateBack() {
    _snapAnim = Tween<double>(begin: _dragY, end: 0).animate(CurvedAnimation(parent: _snap, curve: Curves.easeOutCubic));
    _snap..reset()..forward();
  }

  Future<void> _crop() async {
    final asset = widget.items[_cur];
    final file = await asset.originFile;
    if (file == null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('File not found')));
      return;
    }

    final cropped = await ImageCropper().cropImage(
      sourcePath: file.path,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop',
          toolbarColor: Colors.black,
          toolbarWidgetColor: Colors.white,
          backgroundColor: Colors.black,
          activeControlsWidgetColor: Theme.of(context).colorScheme.primary,
          lockAspectRatio: false,
        ),
        IOSUiSettings(title: 'Crop'),
      ],
    );
    if (cropped == null) return; 

    final saved = await PhotoManager.editor.saveImageWithPath(cropped.path, title: 'crop_${DateTime.now().millisecondsSinceEpoch}.jpg');

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(saved != null ? 'Cropped image saved' : 'Save failed')));
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final n = widget.items.length;
    final cur = widget.items[_cur];
    final fade = (1 - _dragY.abs() / 320).clamp(0.0, 1.0);
    final dp = context.watch<ThemeProvider>().p;
    final showBar = _chrome && !_zoomed;

    return PopScope(
      onPopInvokedWithResult: (didPop, _) { if (didPop) _showSystemUi(); },
      child: Scaffold(
        backgroundColor: dp.bg, // 👈 మార్పు: థీమ్ బ్యాక్గ్రౌండ్ వాడాం 
        body: Stack(fit: StackFit.expand, children: [
          Opacity(
            opacity: fade,
            child: Stack(fit: StackFit.expand, children: [
              ColoredBox(color: dp.bg), 
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
              ColoredBox(color: dp.bg.withValues(alpha: 0.7)),
            ]),
          ),
          GestureDetector(
            onVerticalDragUpdate: _zoomed ? null : (d) => setState(() => _dragY += d.delta.dy),
            onVerticalDragEnd: _zoomed
                ? null
                : (d) {
                    final v = d.primaryVelocity ?? 0;
                    if (_dragY.abs() > 120 || v.abs() > 900) Navigator.of(context).pop();
                    else _animateBack();
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
                    key: ValueKey(widget.items[i].id), asset: widget.items[i], thumbPx: widget.thumbPx,
                    onZoom: (z) { if (i == _cur && z != _zoomed) setState(() => _zoomed = z); },
                    onTap: _toggleChrome,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0, left: 0, right: 0,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200), opacity: showBar ? fade : 0,
              child: IgnorePointer(
                ignoring: !showBar,
                child: _Glass(
                  p: dp, radius: 0, blur: 26, border: Border(bottom: BorderSide(color: dp.border)),
                  child: Padding(
                    padding: EdgeInsets.only(top: mq.padding.top),
                    child: SizedBox(
                      height: 56,
                      child: Row(children: [
                        IconButton(icon: Icon(Icons.arrow_back_ios_new_rounded, color: dp.text, size: 20), onPressed: () => Navigator.of(context).pop()),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(DateFormat('d MMM yyyy').format(cur.createDateTime), style: TextStyle(color: dp.text, fontSize: 16, fontWeight: FontWeight.w700)),
                              Text('${_cur + 1} / $n', style: TextStyle(color: dp.sub, fontSize: 12)),
                            ],
                          ),
                        ),
                        IconButton(tooltip: 'Crop', icon: Icon(Icons.crop_rounded, color: dp.text), onPressed: _crop),
                        IconButton(tooltip: 'Details', icon: Icon(Icons.info_outline_rounded, color: dp.text), onPressed: () => _showMeta(context, dp, cur)),
                        const SizedBox(width: 4),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _ZoomPage extends StatefulWidget {
  const _ZoomPage({super.key, required this.asset, required this.thumbPx, required this.onZoom, required this.onTap});
  final AssetEntity asset;
  final int thumbPx;
  final ValueChanged<bool> onZoom;
  final VoidCallback onTap;

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
  void dispose() { _anim.dispose(); _tc.dispose(); super.dispose(); }

  void _report() {
    final s = _tc.value.getMaxScaleOnAxis();
    final z = s > 1.03;
    if (z != _zoomed) { setState(() => _zoomed = z); widget.onZoom(z); }
    if (!_orig && s > 1.4) setState(() => _orig = true);
  }

  void _doubleTap() {
    final from = _tc.value;
    final zoomedNow = from.getMaxScaleOnAxis() > 1.05;
    const s = 2.6;
    final to = zoomedNow ? Matrix4.identity() : Matrix4(s, 0, 0, 0, 0, s, 0, 0, 0, 0, 1, 0, -_tap.dx * (s - 1), -_tap.dy * (s - 1), 0, 1);
    _tween = Matrix4Tween(begin: from, end: to);
    _anim..reset()..forward();
  }

  // 👈 మార్పు: Fade image కి BoxFit.contain వాడాం 
  Widget _fade(ImageProvider p) => Image(
        image: p, fit: BoxFit.contain, gaplessPlayback: true,
        frameBuilder: (c, child, frame, sync) => AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 220), child: child),
      );

  @override
  Widget build(BuildContext context) {
    final a = widget.asset;
    final thumb = AssetEntityImageProvider(a, isOriginal: false, thumbnailSize: ThumbnailSize.square(widget.thumbPx));
    final big = AssetEntityImageProvider(a, isOriginal: false, thumbnailSize: const ThumbnailSize(1440, 1440));

    return GestureDetector(
      behavior: HitTestBehavior.opaque, onTap: widget.onTap, onDoubleTapDown: (d) => _tap = d.localPosition, onDoubleTap: _doubleTap,
      child: InteractiveViewer(
        transformationController: _tc, minScale: 1, maxScale: 6,
        onInteractionUpdate: (_) => _report(), onInteractionEnd: (_) => _report(),
        // 👈 మార్పు: LayoutBuilder తీసేసి డైరెక్ట్ గా సెంటర్ లో ఇమేజ్ ని పెట్టేశాం
        child: Center(
          child: Hero(
            tag: 'photo_${a.id}', flightShuttleBuilder: _shuttle(thumb),
            child: Stack(fit: StackFit.expand, children: [
              Image(image: thumb, fit: BoxFit.contain, gaplessPlayback: true),
              _fade(big),
              if (_orig) _fade(AssetEntityImageProvider(a, isOriginal: true)),
            ]),
          ),
        ),
      ),
    );
  }
}