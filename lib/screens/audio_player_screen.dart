import 'dart:io';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import '../core/theme_provider.dart';

class AudioPlayerScreen extends StatefulWidget {
  final File file;
  final String title;

  const AudioPlayerScreen({super.key, required this.file, required this.title});

  @override
  State<AudioPlayerScreen> createState() => _AudioPlayerScreenState();
}

class _AudioPlayerScreenState extends State<AudioPlayerScreen> {
  final AudioPlayer _player = AudioPlayer();
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      await _player.setFilePath(widget.file.path);
      _player.durationStream.listen((d) { if (mounted && d != null) setState(() => _duration = d); });
      _player.positionStream.listen((p) { if (mounted) setState(() => _position = p); });
      _player.playingStream.listen((playing) { if (mounted) setState(() => _isPlaying = playing); });
      _player.play();
    } catch (e) {
      debugPrint("Audio Error: $e");
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final min = d.inMinutes;
    final sec = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$min:$sec';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<ThemeProvider>().p;
    
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: p.text),
        title: Text('Now Playing', style: TextStyle(color: p.text, fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 👈 గ్లాసీ మ్యూజిక్ డిస్క్ (Vinyl Style)
            Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [p.accent, p.accent.withOpacity(0.4)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [BoxShadow(color: p.accent.withOpacity(0.3), blurRadius: 40, spreadRadius: 10)]
              ),
              child: const Center(
                child: Icon(Icons.music_note_rounded, size: 120, color: Colors.white),
              ),
            ),
            const SizedBox(height: 48),
            Text(
              widget.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(color: p.text, fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 32),
            
            // 👈 ఆడియో స్లైడర్
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: p.accent,
                inactiveTrackColor: p.border,
                thumbColor: p.accent,
                trackHeight: 6.0,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8.0),
              ),
              child: Slider(
                min: 0.0,
                max: _duration.inMilliseconds.toDouble() > 0 ? _duration.inMilliseconds.toDouble() : 1.0,
                value: _position.inMilliseconds.toDouble().clamp(0.0, _duration.inMilliseconds.toDouble() > 0 ? _duration.inMilliseconds.toDouble() : 1.0),
                onChanged: (val) {
                  _player.seek(Duration(milliseconds: val.toInt()));
                },
              ),
            ),
            
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(_position), style: TextStyle(color: p.sub, fontWeight: FontWeight.bold)),
                  Text(_fmt(_duration), style: TextStyle(color: p.sub, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const SizedBox(height: 32),
            
            // 👈 ఆడియో కంట్రోల్స్ (Play, Pause, Rewind)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  iconSize: 42, color: p.text, icon: const Icon(Icons.replay_10_rounded),
                  onPressed: () {
                    final newPos = _position - const Duration(seconds: 10);
                    _player.seek(newPos < Duration.zero ? Duration.zero : newPos);
                  },
                ),
                const SizedBox(width: 24),
                GestureDetector(
                  onTap: () => _isPlaying ? _player.pause() : _player.play(),
                  child: Container(
                    width: 76, height: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle, color: p.accent,
                      boxShadow: [BoxShadow(color: p.accent.withOpacity(0.4), blurRadius: 20, offset: const Offset(0, 8))]
                    ),
                    child: Icon(_isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 40),
                  ),
                ),
                const SizedBox(width: 24),
                IconButton(
                  iconSize: 42, color: p.text, icon: const Icon(Icons.forward_10_rounded),
                  onPressed: () {
                    final newPos = _position + const Duration(seconds: 10);
                    _player.seek(newPos > _duration ? _duration : newPos);
                  },
                ),
              ],
            )
          ],
        ),
      ),
    );
  }
}