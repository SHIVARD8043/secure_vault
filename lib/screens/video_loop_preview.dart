import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Muted, looping preview (default first 5 seconds) - works like a GIF inside a thumbnail.
/// Put it on top of the thumbnail image. It fades in once the first frame is ready,
/// so the thumbnail stays visible until then.
///
/// Usage (gallery):  VideoLoopPreview(loadFile: () => asset.originFile)
/// Usage (vault):    VideoLoopPreview(loadFile: () async => File(item.encryptedPath))
class VideoLoopPreview extends StatefulWidget {
  const VideoLoopPreview({super.key, required this.loadFile, this.seconds = 5});
  final Future<File?> Function() loadFile;
  final int seconds;

  @override
  State<VideoLoopPreview> createState() => _VideoLoopPreviewState();
}

class _VideoLoopPreviewState extends State<VideoLoopPreview> {
  VideoPlayerController? _c;
  Timer? _timer;
  bool _ready = false, _dead = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final f = await widget.loadFile();
      if (_dead || f == null) return;
      final c = VideoPlayerController.file(f, videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true));
      _c = c;
      await c.initialize();
      if (_dead) return; // already disposed in dispose()
      await c.setVolume(0);
      await c.setLooping(true);
      await c.play();
      final limit = Duration(seconds: widget.seconds);
      _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        final v = c.value;
        if (v.isInitialized && v.position >= limit) c.seekTo(Duration.zero);
      });
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      // ignore - thumbnail stays visible
    }
  }

  @override
  void dispose() {
    _dead = true;
    _timer?.cancel();
    final c = _c;
    _c = null;
    c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null || !_ready) return const SizedBox.shrink();
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 250),
        builder: (_, v, child) => Opacity(opacity: v, child: child),
        child: SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: c.value.size.width,
              height: c.value.size.height,
              child: VideoPlayer(c),
            ),
          ),
        ),
      ),
    );
  }
}
