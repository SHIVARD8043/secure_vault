import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../core/theme_provider.dart';
import 'home_preview_screen.dart';
import '../core/vault_service.dart';
import '../db/database_helper.dart';
import '../db/vault_item_model.dart';
import 'package:provider/provider.dart';

/// Finds byte-for-byte duplicate files across the device gallery and Secure Vault.
class DuplicateFinderScreen extends StatefulWidget {
  const DuplicateFinderScreen({super.key});

  @override
  State<DuplicateFinderScreen> createState() => _DuplicateFinderScreenState();
}

class _DuplicateEntry {
  const _DuplicateEntry({
    required this.name,
    required this.path,
    required this.location,
    required this.size,
    required this.hash,
    required this.createdAt,
    this.assetId,
    this.asset,
    this.vaultItem,
  });

  final String name;
  final String path;
  final String location;
  final int size;
  final String hash;
  final DateTime? createdAt;
  final String? assetId;
  final AssetEntity? asset;
  final VaultItem? vaultItem;
}

class _DuplicateFinderScreenState extends State<DuplicateFinderScreen> {
  bool _scanning = false;
  bool _finished = false;
  double _progress = 0;
  int _processed = 0;
  int _total = 0;
  String _status = 'Scan Gallery and Vault for exact duplicates.';
  List<List<_DuplicateEntry>> _groups = [];
  String? _error;
  final Set<String> _deletingPaths = <String>{};
  final Set<String> _markedPaths = <String>{};

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _finished = false;
      _progress = 0;
      _processed = 0;
      _total = 0;
      _groups = [];
      _markedPaths.clear();
      _error = null;
      _status = 'Checking permissions...';
    });

    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth && !permission.hasAccess) {
        throw Exception('Gallery permission denied. Allow photo/video access and try again.');
      }

      final vaultItems = await DatabaseHelper.instance.fetchAll();
      final vaultEntries = <_DuplicateEntry>[];
      for (final item in vaultItems) {
        if (item.isDeleted != 0 || item.type == 'folder') continue;
        final file = File(item.encryptedPath);
        if (!await file.exists()) continue;
        vaultEntries.add(_DuplicateEntry(
          name: item.originalName.isNotEmpty ? item.originalName : file.uri.pathSegments.last,
          path: file.path,
          location: 'Secure Vault',
          size: await file.length(),
          hash: '',
          createdAt: (item.takenMs ?? 0) > 0
              ? DateTime.fromMillisecondsSinceEpoch(item.takenMs!)
              : DateTime.tryParse(item.addedDate),
          vaultItem: item,
        ));
      }

      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        onlyAll: true,
      );
      final assets = <AssetEntity>[];
      if (paths.isNotEmpty) {
        var page = 0;
        const pageSize = 200;
        while (true) {
          final batch = await paths.first.getAssetListPaged(page: page, size: pageSize);
          assets.addAll(batch);
          if (batch.length < pageSize) break;
          page++;
        }
      }

      final galleryFiles = <_DuplicateEntry>[];
      for (final asset in assets) {
        final file = await asset.originFile;
        if (file == null || !await file.exists()) continue;
        galleryFiles.add(_DuplicateEntry(
          name: asset.title ?? file.uri.pathSegments.last,
          path: file.path,
          location: 'Phone Gallery',
          size: await file.length(),
          hash: '',
          createdAt: asset.createDateTime,
          assetId: asset.id,
          asset: asset,
        ));
      }

      final all = <_DuplicateEntry>[...vaultEntries, ...galleryFiles];
      _total = all.length;
      if (mounted) {
        setState(() => _status = 'Verifying file sizes and SHA-256 hashes...');
      }

      // Different file sizes cannot be byte-for-byte duplicates.
      final sizeBuckets = <int, List<_DuplicateEntry>>{};
      for (final entry in all) {
        sizeBuckets.putIfAbsent(entry.size, () => []).add(entry);
      }

      final hashBuckets = <String, List<_DuplicateEntry>>{};
      final candidates = sizeBuckets.values.where((bucket) => bucket.length > 1).expand((e) => e).toList();
      // Count all discovered files in the progress denominator, even files skipped by size filtering.
      _total = all.length;
      var processed = all.length - candidates.length;
      if (mounted) setState(() {
        _processed = processed;
        _progress = _total == 0 ? 1 : processed / _total;
        _status = 'Hashing possible matches...';
      });

      for (final entry in candidates) {
        try {
          final digest = await sha256.bind(File(entry.path).openRead()).first;
          final key = '${entry.size}:$digest';
          hashBuckets.putIfAbsent(key, () => []).add(_DuplicateEntry(
            name: entry.name,
            path: entry.path,
            location: entry.location,
            size: entry.size,
            hash: digest.toString(),
            createdAt: entry.createdAt,
            assetId: entry.assetId,
            asset: entry.asset,
            vaultItem: entry.vaultItem,
          ));
        } catch (_) {
          // Unreadable files are skipped; no duplicate is claimed without a hash.
        }
        processed++;
        if (mounted) setState(() {
          _processed = processed;
          _progress = _total == 0 ? 1 : processed / _total;
        });
      }

      final groups = hashBuckets.values.where((g) => g.length > 1).toList()
        ..sort((a, b) => b.first.size.compareTo(a.first.size));
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _finished = true;
        _scanning = false;
        _progress = 1;
        _processed = _total;
        _status = groups.isEmpty
            ? 'No exact duplicates found.'
            : '${groups.length} duplicate groups found.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = e.toString().replaceFirst('Exception: ', '');
        _status = 'Scan could not be completed.';
      });
    }
  }

  String _formatCreatedAt(DateTime? date) {
    if (date == null) return 'Created: Date unavailable';
    final local = date.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final ampm = local.hour >= 12 ? 'PM' : 'AM';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return 'Created: ${local.day.toString().padLeft(2, '0')} ${months[local.month - 1]} ${local.year}, $hour:$minute $ampm';
  }

  bool _looksLikeImage(String path) {
    final lower = path.toLowerCase();
    return ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.heic', '.heif']
        .any(lower.endsWith);
  }

  Future<void> _openPreview(_DuplicateEntry entry) async {
    // Use the app's existing full-screen gallery preview for gallery images.
    // Vault copies use the file-based preview below because they are not AssetEntity objects.
    if (entry.asset != null && entry.asset!.type == AssetType.image) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => HomePreviewScreen(
            items: [entry.asset!],
            initial: 0,
            thumbPx: 256,
          ),
        ),
      );
      return;
    }

    if (!_looksLikeImage(entry.path)) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(entry.name),
          content: SelectableText('Preview is available for image files.\n\nLocation: ${entry.location}\nPath: ${entry.path}'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        ),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: SafeArea(
          child: Stack(children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 5,
                child: Center(
                  child: Image.file(
                    File(entry.path),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Unable to open this image file.', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 8,
              child: IconButton.filledTonal(
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(Icons.close_rounded),
                tooltip: 'Close preview',
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                child: Text('${entry.name}\n${entry.location}\n${_formatCreatedAt(entry.createdAt)}',
                  maxLines: 4, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  void _toggleMarked(_DuplicateEntry entry, bool marked) {
    setState(() {
      if (marked) {
        _markedPaths.add(entry.path);
      } else {
        _markedPaths.remove(entry.path);
      }
    });
  }

  Future<void> _deleteEntry(_DuplicateEntry entry) async {
    if (_deletingPaths.contains(entry.path)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this copy?'),
        content: Text(entry.location == 'Secure Vault'
            ? 'This will permanently delete "${entry.name}" from Secure Vault.'
            : 'This will request deletion of "${entry.name}" from your Phone Gallery. Android may show a permission confirmation.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deletingPaths.add(entry.path));
    try {
      if (entry.vaultItem != null) {
        await VaultService().deleteForever([entry.vaultItem!]);
      } else if (entry.assetId != null) {
        final deleted = await PhotoManager.editor.deleteWithIds([entry.assetId!]);
        if (deleted.isEmpty) {
          throw Exception('Gallery did not confirm deletion. The item may have been kept or moved to Trash.');
        }
      } else {
        throw Exception('Could not identify this file for safe deletion.');
      }
      if (!mounted) return;
      // Update the current results locally instead of restarting the full scan.
      // A group with fewer than two remaining files is no longer a duplicate group.
      setState(() {
        _markedPaths.remove(entry.path);
        _groups = _groups
            .map((group) => group.where((item) => item.path != entry.path).toList())
            .where((group) => group.length > 1)
            .toList();
        _finished = true;
        _status = _groups.isEmpty
            ? 'No exact duplicates remain in the current results.'
            : '${_groups.length} duplicate groups remaining.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted: ${entry.name}')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: ${e.toString().replaceFirst('Exception: ', '')}')),
        );
      }
    } finally {
      if (mounted) setState(() => _deletingPaths.remove(entry.path));
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<ThemeProvider>().p;
    final duplicateFiles = _groups.fold<int>(0, (sum, group) => sum + group.length);

    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        foregroundColor: p.text,
        title: const Text('Duplicate Finder', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: p.glass,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: p.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.fingerprint_rounded, color: p.accent, size: 30),
                      const SizedBox(width: 10),
                      Expanded(child: Text('Exact match scan', style: TextStyle(color: p.text, fontSize: 18, fontWeight: FontWeight.bold))),
                    ]),
                    const SizedBox(height: 8),
                    Text('Compares Phone Gallery and Secure Vault using file size + SHA-256. Each copy has its own delete action.',
                      style: TextStyle(color: p.sub, fontSize: 13)),
                    const SizedBox(height: 14),
                    if (_scanning) ...[
                      LinearProgressIndicator(value: _progress, color: p.accent, backgroundColor: p.border),
                      const SizedBox(height: 7),
                      Text('$_processed / $_total files checked  ·  ${(_progress * 100).round()}%',
                        style: TextStyle(color: p.text, fontSize: 12)),
                      const SizedBox(height: 8),
                    ],
                    Text(_status, style: TextStyle(color: _error == null ? p.sub : Colors.redAccent, fontSize: 13)),
                    if (_error != null) ...[
                      const SizedBox(height: 6),
                      Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                    ],
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _scanning ? null : _scan,
                        icon: Icon(_scanning ? Icons.hourglass_top_rounded : Icons.search_rounded),
                        label: Text(_scanning ? 'Scanning...' : (_finished ? 'Scan Again' : 'Start Scan')),
                        style: FilledButton.styleFrom(
                          backgroundColor: p.accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_finished && _groups.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                child: Row(children: [
                  Expanded(child: Text('${_groups.length} groups · $duplicateFiles duplicate files',
                    style: TextStyle(color: p.text, fontWeight: FontWeight.bold))),
                  Text('Exact SHA-256 match', style: TextStyle(color: p.sub, fontSize: 11)),
                ]),
              ),
            if (_finished && _groups.isNotEmpty && _markedPaths.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
                child: Row(children: [
                  Expanded(child: Text('${_markedPaths.length} marked for review', style: TextStyle(color: p.accent, fontSize: 12, fontWeight: FontWeight.w600))),
                  TextButton.icon(
                    onPressed: () => setState(() => _markedPaths.clear()),
                    icon: const Icon(Icons.clear_all_rounded, size: 18),
                    label: const Text('Clear marks'),
                  ),
                ]),
              ),
            Expanded(
              child: _groups.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(_finished ? Icons.verified_rounded : Icons.content_copy_rounded,
                            color: p.sub, size: 46),
                          const SizedBox(height: 12),
                          Text(_finished ? 'No exact duplicates found' : 'Gallery + Vault',
                            style: TextStyle(color: p.text, fontSize: 16, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 5),
                          Text(_finished ? 'Files with different contents are not marked as duplicates.'
                              : 'Start a scan to find byte-for-byte matching files.',
                            textAlign: TextAlign.center, style: TextStyle(color: p.sub, fontSize: 13)),
                        ]),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      itemCount: _groups.length,
                      itemBuilder: (context, index) {
                        final group = _groups[index];
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: p.glass,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: p.border),
                          ),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('Group ${index + 1} · ${_formatSize(group.first.size)} · ${group.length} copies',
                              style: TextStyle(color: p.text, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            ...group.map((entry) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 7),
                              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Checkbox(
                                  value: _markedPaths.contains(entry.path),
                                  onChanged: (value) => _toggleMarked(entry, value ?? false),
                                  visualDensity: VisualDensity.compact,
                                  activeColor: p.accent,
                                ),
                                Icon(entry.location == 'Secure Vault' ? Icons.lock_rounded : Icons.photo_library_rounded,
                                  color: p.accent, size: 21),
                                const SizedBox(width: 7),
                                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  InkWell(
                                    onTap: () => _openPreview(entry),
                                    child: Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                                      style: TextStyle(color: p.text, fontWeight: FontWeight.w600, fontSize: 13, decoration: TextDecoration.underline)),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(entry.location, style: TextStyle(color: p.accent, fontSize: 11, fontWeight: FontWeight.w600)),
                                  Text(_formatCreatedAt(entry.createdAt), style: TextStyle(color: p.text, fontSize: 11)),
                                  SelectableText(entry.path,
                                    style: TextStyle(color: p.sub, fontSize: 10)),
                                ])),
                                const SizedBox(width: 4),
                                IconButton(
                                  tooltip: 'Open image / file details',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => _openPreview(entry),
                                  icon: Icon(_looksLikeImage(entry.path) ? Icons.open_in_full_rounded : Icons.info_outline_rounded,
                                    color: p.accent, size: 20),
                                ),
                                IconButton(
                                  tooltip: 'Delete this copy',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: _scanning || _deletingPaths.contains(entry.path) ? null : () => _deleteEntry(entry),
                                  icon: _deletingPaths.contains(entry.path)
                                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                      : const Icon(Icons.delete_forever_rounded, color: Colors.redAccent, size: 22),
                                ),
                              ]),
                            )),
                          ]),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
