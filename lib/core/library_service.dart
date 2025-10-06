import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'library_item.dart';

class LibraryService {
  static const _k = 'atelier.items';
  final changes = ChangeNotifier();

  Future<List<LibraryItem>> getAll() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_k);
    if (raw == null || raw.isEmpty) return <LibraryItem>[];
    return LibraryItem.decodeList(raw);
  }

  Future<void> _saveAll(List<LibraryItem> items) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_k, LibraryItem.encodeList(items));
    changes.notifyListeners();
  }

  Future<void> addItem(LibraryItem it) async {
    final items = await getAll();
    // évite doublons par URL
    if (items.any((e) => e.url == it.url)) return;
    items.insert(0, it);
    await _saveAll(items);
  }

  Future<void> removeById(String id) async {
    final items = await getAll();
    items.removeWhere((e) => e.id == id);
    await _saveAll(items);
  }

  Future<void> updateNotes(String id, String notes) async {
    final items = await getAll();
    final i = items.indexWhere((e) => e.id == id);
    if (i < 0) return;
    items[i] = items[i].copyWith(notes: notes);
    await _saveAll(items);
  }

  // Manquantes dans ton AtelierScreen :
  Future<void> updateTitle(String id, String title) async {
    final items = await getAll();
    final i = items.indexWhere((e) => e.id == id);
    if (i < 0) return;
    items[i] = items[i].copyWith(title: title);
    await _saveAll(items);
  }

  Future<void> touchViewed(String id) async {
    final items = await getAll();
    final i = items.indexWhere((e) => e.id == id);
    if (i < 0) return;
    items[i] = items[i].copyWith(lastViewedAt: DateTime.now());
    await _saveAll(items);
  }

  // Tags & type (facultatif mais prêt)
  Future<void> updateTags(String id, List<String> tags) async {
    final items = await getAll();
    final i = items.indexWhere((e) => e.id == id);
    if (i < 0) return;
    items[i] = items[i].copyWith(tags: tags);
    await _saveAll(items);
  }

  Future<void> updateKind(String id, String kind) async {
    final items = await getAll();
    final i = items.indexWhere((e) => e.id == id);
    if (i < 0) return;
    items[i] = items[i].copyWith(kind: kind);
    await _saveAll(items);
  }

  // Export/Import playlists (JSON)
  Future<String> exportJson() async => LibraryItem.encodeList(await getAll());
  Future<void> importJson(String raw) async {
    final imported = LibraryItem.decodeList(raw);
    final current = await getAll();
    final seen = current.map((e) => e.id).toSet();
    current.addAll(imported.where((e) => !seen.contains(e.id)));
    await _saveAll(current);
  }

  // 🔥 AJOUT : ajout automatique à partir d’une URL YouTube partagée
  Future<void> addFromUrl(String rawUrl, {String? title, String kind = 'teacher'}) async {
    final url = _normalizeYoutubeUrl(rawUrl);
    final items = await getAll();

    // Déduplication simple
    final exist = items.indexWhere((e) => e.url == url);
    if (exist >= 0) {
      items[exist] = items[exist].copyWith(lastViewedAt: DateTime.now());
      await _saveAll(items);
      return;
    }

    final it = LibraryItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: (title != null && title.trim().isNotEmpty)
          ? title.trim()
          : _guessTitleFromUrl(url),
      url: url,
      source: 'youtube',
      kind: kind, // 'teacher' ou 'backing'
    );
    items.insert(0, it);
    await _saveAll(items);
  }

  // 🔧 Helpers privés
  String _normalizeYoutubeUrl(String input) {
    final s = input.trim();
    final uri = Uri.tryParse(s);
    if (uri == null) return s;

    // youtube.com/watch?v=...
    final v = uri.queryParameters['v'];
    if (v != null && v.isNotEmpty) return 'https://youtu.be/$v';

    // youtu.be/<id>
    if (uri.host.contains('youtu.be') && uri.pathSegments.isNotEmpty) {
      return 'https://youtu.be/${uri.pathSegments.first}';
    }

    // youtube.com/shorts/<id>
    if (uri.host.contains('youtube.com') &&
        uri.pathSegments.isNotEmpty &&
        uri.pathSegments.first == 'shorts' &&
        uri.pathSegments.length >= 2) {
      return 'https://youtu.be/${uri.pathSegments[1]}';
    }

    return s; // fallback
  }

  String _guessTitleFromUrl(String url) => 'YouTube video';
}