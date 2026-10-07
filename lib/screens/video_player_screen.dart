import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

/// Light-weight player: tap = show/hide controls, double-tap left/right = -10s/+10s,
/// seek bar, play/pause. Works for gallery files and vault files (just pass a File).
class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({super.key, required this.file, this.title});
  final File file;
  final String? title;

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late final VideoPlayerController _c;
  bool _ready = false, _error = false, _show = true;
  double? _drag;
  Timer? _hideTimer;
  TapDownDetails? _dt;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _c = VideoPlayerController.file(widget.file);
    _c.initialize().then((_) {
      if (!mounted) return;
      setState(() => _ready = true);
      _c.play();
      _bump();
    }).catchError((_) {
      if (mounted) setState(() => _error = true);
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _c.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _bump() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _c.value.isPlaying) setState(() => _show = false);
    });
  }

  void _toggleUi() {
    setState(() => _show = !_show);
    if (_show) _bump();
  }

  void _playPause() {
    _c.value.isPlaying ? _c.pause() : _c.play();
    _bump();
  }

  void _skip(int sec) {
    final v = _c.value;
    var t = v.position + Duration(seconds: sec);
    if (t < Duration.zero) t = Duration.zero;
    if (t > v.duration) t = v.duration;
    _c.seekTo(t);
    _bump();
  }

  String _fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes.remainder(60), s = d.inSeconds.remainder(60);
    final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0'), ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return Scaffold(
      backgroundColor: Colors.black,
      body: _error
          ? const Center(child: Text("Video play avvatledu", style: TextStyle(color: Colors.white70)))
          : !_ready
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleUi,
                  onDoubleTapDown: (d) => _dt = d,
                  onDoubleTap: () => _skip((_dt?.localPosition.dx ?? w) < w / 2 ? -10 : 10),
                  child: Stack(fit: StackFit.expand, children: [
                    Center(child: AspectRatio(aspectRatio: _c.value.aspectRatio, child: VideoPlayer(_c))),
                    AnimatedOpacity(
                      opacity: _show ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: IgnorePointer(ignoring: !_show, child: _controls()),
                    ),
                  ]),
                ),
    );
  }

  Widget _controls() {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [Color(0xAA000000), Color(0x00000000), Color(0x00000000), Color(0xCC000000)],
          stops: [0, 0.25, 0.7, 1],
        ),
      ),
      child: SafeArea(
        child: Column(children: [
          Row(children: [
            IconButton(icon: const Icon(Icons.arrow_back_rounded, color: Colors.white), onPressed: () => Navigator.pop(context)),
            Expanded(child: Text(widget.title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600))),
          ]),
          const Spacer(),
          ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: _c,
            builder: (_, v, __) => GestureDetector(
              onTap: _playPause,
              child: Container(
                width: 68, height: 68,
                decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.18), border: Border.all(color: Colors.white24)),
                child: Icon(v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 40),
              ),
            ),
          ),
          const Spacer(),
          ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: _c,
            builder: (_, v, __) {
              final total = v.duration.inMilliseconds.toDouble().clamp(1.0, double.infinity);
              final cur = (_drag ?? v.position.inMilliseconds.toDouble()).clamp(0.0, total);
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Row(children: [
                  Text(_fmt(Duration(milliseconds: cur.toInt())), style: const TextStyle(color: Colors.white, fontSize: 12)),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                        activeTrackColor: Colors.white, inactiveTrackColor: Colors.white24, thumbColor: Colors.white,
                        overlayShape: SliderComponentShape.noOverlay,
                      ),
                      child: Slider(
                        value: cur, max: total,
                        onChangeStart: (_) => _hideTimer?.cancel(),
                        onChanged: (x) => setState(() => _drag = x),
                        onChangeEnd: (x) {
                          _c.seekTo(Duration(milliseconds: x.toInt()));
                          setState(() => _drag = null);
                          _bump();
                        },
                      ),
                    ),
                  ),
                  Text(_fmt(v.duration), style: const TextStyle(color: Colors.white, fontSize: 12)),
                ]),
              );
            },
          ),
        ]),
      ),
    );
  }
}
