import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/app_prefs.dart';
import '../models/download_models.dart';

/// Download history, newest first, stored as JSON in SharedPreferences.
class HistoryStore extends ChangeNotifier {
  HistoryStore(this._prefs) {
    for (final raw in _prefs.historyJson) {
      try {
        final entry = HistoryEntry.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
        if (entry != null) _entries.add(entry);
      } catch (_) {}
    }
    _entries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  static const _maxEntries = 500;

  final AppPrefs _prefs;
  final List<HistoryEntry> _entries = [];

  List<HistoryEntry> get entries => List.unmodifiable(_entries);

  Future<void> add(HistoryEntry entry) async {
    _entries.removeWhere((e) => e.id == entry.id);
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
