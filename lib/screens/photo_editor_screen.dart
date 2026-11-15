import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

// ─────────────────────────────────────────────────────────────
// COLOR MATRIX HELPERS (4x5, Flutter ColorFilter format)
// ─────────────────────────────────────────────────────────────
const List<double> _id = [
  1, 0, 0, 0, 0,
  0, 1, 0, 0, 0,
  0, 0, 1, 0, 0,
  0, 0, 0, 1, 0,
];

/// Result = A applied after B.
List<double> _mul(List<double> a, List<double> b) {
  final r = List<double>.filled(20, 0);
  for (var i = 0; i < 4; i++) {
    for (var j = 0; j < 5; j++) {
      var s = 0.0;
      for (var k = 0; k < 4; k++) {
        s += a[i * 5 + k] * b[k * 5 + j];
      }
      if (j == 4) s += a[i * 5 + 4];
      r[i * 5 + j] = s;
    }
  }
  return r;
}

/// Applies steps in the given order.
List<double> _chain(List<List<double>> steps) {
  var m = _id;
  for (final s in steps) {
    m = _mul(s, m);
  }
  return m;
}

List<double> _bright(double v) {
  final o = v * 255 * 0.4;
  return [1, 0, 0, 0, o, 0, 1, 0, 0, o, 0, 0, 1, 0, o, 0, 0, 0, 1, 0];
}

List<double> _contrast(double v) {
  final f = 1 + v;
  final o = 255 * 0.5 * (1 - f);
  return [f, 0, 0, 0, o, 0, f, 0, 0, o, 0, 0, f, 0, o, 0, 0, 0, 1, 0];
}

List<double> _sat(double v) {
  final s = 1 + v;
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final ir = lr * (1 - s), ig = lg * (1 - s), ib = lb * (1 - s);
  return [
    ir + s, ig, ib, 0, 0,
    ir, ig + s, ib, 0, 0,
    ir, ig, ib + s, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

List<double> _warm(double v) =>
    [1, 0, 0, 0, v * 24, 0, 1, 0, 0, 0, 0, 0, 1, 0, -v * 24, 0, 0, 0, 1, 0];

List<double> _tint(double v) =>
    [1, 0, 0, 0, v * 9, 0, 1, 0, 0, -v * 18, 0, 0, 1, 0, v * 9, 0, 0, 0, 1, 0];

List<double> _fade(double v) {
  final s = 1 - 0.25 * v;
  final o = 255 * 0.1 * v;
  return [s, 0, 0, 0, o, 0, s, 0, 0, o, 0, 0, s, 0, o, 0, 0, 0, 1, 0];
}

class _Preset {
  _Preset(this.name, this.m);
  final String name;
  final List<double> m;
}

final List<_Preset> _presets = [
  _Preset('Original', _id),
  _Preset('Vivid', _chain([_sat(0.45), _contrast(0.12)])),
  _Preset('Warm', _chain([_warm(0.7), _sat(0.1)])),
  _Preset('Cool', _chain([_warm(-0.7), _sat(0.05)])),
  _Preset('Fade', _chain([_fade(0.6), _sat(-0.15)])),
  _Preset('B&W', _chain([_sat(-1), _contrast(0.15)])),
  _Preset('Noir', _chain([_sat(-1), _contrast(0.4), _bright(-0.08)])),
  _Preset('Sepia', const [
    0.393, 0.769, 0.189, 0, 0,
    0.349, 0.686, 0.168, 0, 0,
    0.272, 0.534, 0.131, 0, 0,
    0, 0, 0, 1, 0,
  ]),
];

// ─────────────────────────────────────────────────────────────
// SCREEN  (pops with the edited File, or null if cancelled)
// ─────────────────────────────────────────────────────────────
class PhotoEditorScreen extends StatefulWidget {
  const PhotoEditorScreen({super.key, required this.file, this.title});
  final File file;
  final String? title;

  @override
  State<PhotoEditorScreen> createState() => _PhotoEditorScreenState();
}

class _PhotoEditorScreenState extends State<PhotoEditorScreen> {
  static const _accent = Color(0xFFB794FF);
  static const _panel = Color(0xFF101116);

  int _preset = 0;
  int _tab = 0; // 0 = Filters, 1 = Adjust
  String _sel = 'Brightness';
  bool _orig = false;
  bool _saving = false;

  final Map<String, double> _v = {
    'Brightness': 0,
    'Contrast': 0,
    'Saturation': 0,
    'Warmth': 0,
    'Tint': 0,
    'Fade': 0,
  };

  List<double> get _matrix => _chain([
        _presets[_preset].m,
        _bright(_v['Brightness']!),
        _contrast(_v['Contrast']!),
        _sat(_v['Saturation']!),
        _warm(_v['Warmth']!),
        _tint(_v['Tint']!),
        _fade(_v['Fade']!),
      ]);

  bool get _dirty => _preset != 0 || _v.values.any((x) => x != 0);

  void _reset() {
    HapticFeedback.selectionClick();
    setState(() {
      _preset = 0;
      for (final k in _v.keys) {
        _v[k] = 0;
      }
    });
  }

  Future<void> _confirmClose() async {
    if (!_dirty) {
      Navigator.pop(context);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16181F),
        title: const Text('Discard edits?', style: TextStyle(color: Colors.white)),
        content: const Text('Cheppina changes anni povu.', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep editing')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard', style: TextStyle(color: Color(0xFFFF647C))),
          ),
        ],
      ),
    );
    if (ok == true && mounted) Navigator.pop(context);
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_dirty) {
      Navigator.pop(context);
      return;
    }
    setState(() => _saving = true);
    try {
      final bytes = await widget.file.readAsBytes();
      final res = await compute(_applyEdits, <Object>[bytes, _matrix]);
      if (res == null) throw 'decode failed';
      final ext = img.findFormatForData(bytes) == img.ImageFormat.png ? 'png' : 'jpg';
      final dir = await Directory.systemTemp.createTemp('edit_');
      final out = File('${dir.path}/edit_${DateTime.now().millisecondsSinceEpoch}.$ext');
      await out.writeAsBytes(res, flush: true);
      if (mounted) Navigator.pop(context, out);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Save cheyyalekapoyam')),
        );
      }
    }
  }

  // ── UI ───────────────────────────────────────────────────────

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 10, 4),
      child: Row(
        children: [
          IconButton(
            onPressed: _confirmClose,
            icon: const Icon(Icons.close_rounded, color: Colors.white),
          ),
          const Expanded(
            child: Text('Edit photo',
                style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
          ),
          Listener(
            onPointerDown: (_) => setState(() => _orig = true),
            onPointerUp: (_) => setState(() => _orig = false),
            onPointerCancel: (_) => setState(() => _orig = false),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(_orig ? 0.2 : 0.08),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.compare_rounded, color: Colors.white, size: 18),
                SizedBox(width: 6),
                Text('Hold', style: TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
          IconButton(
            tooltip: 'Reset',
            onPressed: _dirty ? _reset : null,
            icon: Icon(Icons.restart_alt_rounded, color: _dirty ? Colors.white : Colors.white24),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _accent, foregroundColor: Colors.black),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Text('Save', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }

  Widget _filtersTab() {
    return SizedBox(
      height: 108,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        scrollDirection: Axis.horizontal,
        itemCount: _presets.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final p = _presets[i];
          final on = i == _preset;
          return GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _preset = i);
            },
            child: Column(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 72, height: 72,
                  padding: const EdgeInsets.all(2.5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: on ? _accent : Colors.white12, width: on ? 2 : 1),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(13),
                    child: ColorFiltered(
                      colorFilter: ColorFilter.matrix(p.m),
                      child: Image.file(widget.file, fit: BoxFit.cover, cacheWidth: 180, gaplessPlayback: true),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(p.name,
                    style: TextStyle(
                      color: on ? _accent : Colors.white70,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    )),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _adjustTab() {
    final val = _v[_sel]!;
    final isFade = _sel == 'Fade';
    return SizedBox(
      height: 108,
      child: Column(
        children: [
          SizedBox(
            height: 40,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              scrollDirection: Axis.horizontal,
              children: [
                for (final k in _v.keys)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(k),
                      selected: k == _sel,
                      showCheckmark: false,
                      selectedColor: _accent.withOpacity(0.25),
                      backgroundColor: Colors.white.withOpacity(0.07),
                      side: BorderSide(color: k == _sel ? _accent : Colors.transparent),
                      labelStyle: TextStyle(
                        color: _v[k] != 0 ? _accent : Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                      onSelected: (_) => setState(() => _sel = k),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: _accent,
                    thumbColor: _accent,
                    inactiveTrackColor: Colors.white24,
                    overlayColor: _accent.withOpacity(0.15),
                  ),
                  child: Slider(
                    min: isFade ? 0 : -1,
                    max: 1,
                    value: val,
                    onChanged: (x) => setState(() => _v[_sel] = x),
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => setState(() => _v[_sel] = 0), // tap = reset this one
                child: Container(
                  width: 50,
                  margin: const EdgeInsets.only(right: 16),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('${(val * 100).round()}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tabBtn(int i, IconData icon, String label) {
    final on = _tab == i;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _tab = i),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: on ? _accent : Colors.white54),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                    color: on ? _accent : Colors.white54,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  )),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmClose();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              _topBar(),
              Expanded(
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 5,
                  child: Center(
                    child: ColorFiltered(
                      colorFilter: ColorFilter.matrix(_orig ? _id : _matrix),
                      child: Image.file(
                        widget.file,
                        fit: BoxFit.contain,
                        cacheWidth: 2000,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 54),
                      ),
                    ),
                  ),
                ),
              ),
              Container(
                decoration: const BoxDecoration(
                  color: _panel,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 14),
                    _tab == 0 ? _filtersTab() : _adjustTab(),
                    const Divider(height: 1, color: Colors.white10),
                    Row(children: [
                      _tabBtn(0, Icons.auto_awesome_rounded, 'Filters'),
                      _tabBtn(1, Icons.tune_rounded, 'Adjust'),
                    ]),
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

// ─────────────────────────────────────────────────────────────
// ISOLATE WORKER: same matrix as the preview, applied per pixel
// ─────────────────────────────────────────────────────────────
Uint8List? _applyEdits(List<Object> args) {
  final bytes = args[0] as Uint8List;
  final m = (args[1] as List).cast<double>();

  var im = img.decodeImage(bytes);
  if (im == null) return null;
  im = img.bakeOrientation(im);
  im = im.convert(format: img.Format.uint8, numChannels: 4);

  for (final p in im) {
    final r = p.r.toDouble(), g = p.g.toDouble(), b = p.b.toDouble();
    p.r = (m[0] * r + m[1] * g + m[2] * b + m[4]).clamp(0, 255);
    p.g = (m[5] * r + m[6] * g + m[7] * b + m[9]).clamp(0, 255);
    p.b = (m[10] * r + m[11] * g + m[12] * b + m[14]).clamp(0, 255);
  }

  final isPng = img.findFormatForData(bytes) == img.ImageFormat.png;
  return Uint8List.fromList(isPng ? img.encodePng(im) : img.encodeJpg(im, quality: 95));
}