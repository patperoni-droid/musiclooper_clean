import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

const _kLibKey = 'yt.library.items.v1';

class LibraryItem {
  final String id;        // uid simple (timestamp)
  final String url;       // URL YouTube
  final String? title;    // facultatif (on peut la remplir plus tard)
  final DateTime addedAt; // date d’ajout
  final bool isBacking;   // tag rapide

  LibraryItem({
    required this.id,
    required this.url,
    this.title,
    required this.addedAt,
    this.isBacking = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'title': title,
    'addedAt': addedAt.toIso8601String(),
    'isBacking': isBacking,
  };

  static LibraryItem fromJson(Map<String, dynamic> j) => LibraryItem(
    id: j['id'] as String,
    url: j['url'] as String,
    title: j['title'] as String?,
    addedAt: DateTime.tryParse(j['addedAt'] as String? ?? '') ?? DateTime.now(),
    isBacking: j['isBacking'] as bool? ?? false,
  );
}

class LibraryStore {
  static Future<List<LibraryItem>> load() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_kLibKey) ?? const [];
    return raw.map((s) => LibraryItem.fromJson(jsonDecode(s))).toList();
  }

  static Future<void> save(List<LibraryItem> items) async {
    final sp = await SharedPreferences.getInstance();
    final raw = items.map((e) => jsonEncode(e.toJson())).toList();
    await sp.setStringList(_kLibKey, raw);
  }

  static Future<void> addUrl(String url, {String? title, bool isBacking = false}) async {
    final items = await load();
    final item = LibraryItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      url: url.trim(),
      title: title,
      addedAt: DateTime.now(),
      isBacking: isBacking,
    );
    items.insert(0, item);
    await save(items);
  }

  static Future<void> remove(String id) async {
    final items = await load();
    items.removeWhere((e) => e.id == id);
    await save(items);
  }

  static Future<void> clear() => save([]);
}