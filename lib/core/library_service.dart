// lib/core/library_service.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';          // <- pour ValueNotifier
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'library_item.dart';

class LibraryService {
  LibraryService._();
  static final LibraryService _instance = LibraryService._();
  factory LibraryService() => _instance;

  /// Notifie l’UI dès qu’il y a un ajout/suppression/modification
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  List<LibraryItem> _items = [];
  bool _loaded = false;

  Future<File> _dbFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'library.json'));
    if (!await file.exists()) {
      await file.create(recursive: true);
      await file.writeAsString('[]');
    }
    return file;
  }

  Future<void> _load() async {
    if (_loaded) return;
    final file = await _dbFile();
    try {
      final txt = await file.readAsString();
      final List<dynamic> arr = jsonDecode(txt) as List;

// si ton modèle attend un String JSON, on encode les Map en String ;
// s’il y a déjà des String, on les passe tels quels.
      _items = arr.map<LibraryItem>((e) {
        final String jsonString = (e is String) ? e : jsonEncode(e);
        return LibraryItem.fromJson(jsonString);
      }).toList();
    } catch (_) {
      _items = [];
    }
    _loaded = true;
  }

  Future<void> _save() async {
    final file = await _dbFile();
    final arr = _items.map((e) => e.toJson()).toList();
    await file.writeAsString(jsonEncode(arr));
  }

  Future<List<LibraryItem>> getAll() async {
    await _load();
    return List<LibraryItem>.unmodifiable(_items);
  }

  Future<void> addItem(LibraryItem it) async {
    await _load();
    // dédoublonne par URL (facultatif)
    _items.removeWhere((x) => x.url == it.url);
    _items.insert(0, it);
    await _save();
    changes.value++; // <- notifie l’écran Atelier
  }

  Future<void> updateNotes(String id, String notes) async {
    await _load();
    final i = _items.indexWhere((x) => x.id == id);
    if (i != -1) {
      final it = _items[i];
      _items[i] = LibraryItem(
        id: it.id,
        title: it.title,
        url: it.url,
        source: it.source,
        notes: notes,
      );
      await _save();
      changes.value++;
    }
  }

  Future<void> removeById(String id) async {
    await _load();
    _items.removeWhere((x) => x.id == id);
    await _save();
    changes.value++;
  }

  Future<void> clear() async {
    await _load();
    _items.clear();
    await _save();
    changes.value++;
  }
}