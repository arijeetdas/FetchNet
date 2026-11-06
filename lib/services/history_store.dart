import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/app_prefs.dart';
import '../models/download_models.dart';

/// Download history, newest first, stored as JSON in SharedPreferences.
class HistoryStore extends ChangeNotifier {
  HistoryStore(this._prefs) {
    final loaded = <HistoryEntry>[];
    for (final raw in _prefs.historyJson) {
      try {
        final entry = HistoryEntry.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
        if (entry != null) loaded.add(entry);
      } catch (_) {}
    }
    loaded.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _entries.addAll(dedupe(loaded));
    // Clean up duplicates written by earlier versions.
    if (_entries.length != loaded.length) _save();
  }

  static const _maxEntries = 500;

  final AppPrefs _prefs;
  final List<HistoryEntry> _entries = [];

  List<HistoryEntry> get entries => List.unmodifiable(_entries);

  /// Comparable form of a saved file's path (Windows paths ignore case).
  static String? fileKey(HistoryEntry e) {
    final path = e.filePath;
    if (path == null || path.isEmpty) return null;
    final normalized = p.normalize(path);
    return !kIsWeb && Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  /// One record per download and per saved file, newest kept. A file that was
  /// deleted and downloaded again under the same name is the same file.
  @visibleForTesting
  static List<HistoryEntry> dedupe(List<HistoryEntry> newestFirst) {
    final ids = <String>{};
    final files = <String>{};
    return [
      for (final e in newestFirst)
        if (ids.add(e.id) && (e.status != DownloadStatus.completed || fileKey(e) == null || files.add(fileKey(e)!))) e,
    ];
  }

  Future<void> add(HistoryEntry entry) async {
    final key = entry.status == DownloadStatus.completed ? fileKey(entry) : null;
    _entries.removeWhere(
      (e) => e.id == entry.id || (key != null && e.status == DownloadStatus.completed && fileKey(e) == key),
    );
    _entries.insert(0, entry);
    if (_entries.length > _maxEntries) _entries.removeRange(_maxEntries, _entries.length);
    notifyListeners();
    await _save();
  }

  Future<void> remove(String id) async {
    _entries.removeWhere((e) => e.id == id);
    notifyListeners();
    await _save();
  }

  Future<void> clear() async {
    _entries.clear();
    notifyListeners();
    await _save();
  }

  Future<void> _save() => _prefs.setHistoryJson(_entries.map((e) => jsonEncode(e.toJson())).toList());
}
