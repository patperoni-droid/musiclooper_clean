import 'dart:convert';

class LibraryItem {
  final String id;
  String title;
  final String url;
  final String source;          // 'youtube' | 'local'
  String notes;

  // Nouveaux champs (facultatifs mais utiles pour Atelier)
  List<String> tags;
  String kind;                  // 'teacher' ou 'backing'
  final DateTime addedAt;
  DateTime? lastViewedAt;

  LibraryItem({
    required this.id,
    required this.title,
    required this.url,
    required this.source,
    this.notes = '',
    List<String>? tags,
    this.kind = 'teacher',
    DateTime? addedAt,
    this.lastViewedAt,
  })  : tags = tags ?? <String>[],
        addedAt = addedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'url': url,
    'source': source,
    'notes': notes,
    'tags': tags,
    'kind': kind,
    'addedAt': addedAt.toIso8601String(),
    'lastViewedAt': lastViewedAt?.toIso8601String(),
  };

  static LibraryItem fromJson(Map<String, dynamic> m) => LibraryItem(
    id: m['id'] as String,
    title: m['title'] as String,
    url: m['url'] as String,
    source: m['source'] as String,
    notes: (m['notes'] as String?) ?? '',
    tags: (m['tags'] as List?)?.cast<String>() ?? <String>[],
    kind: (m['kind'] as String?) ?? 'teacher',
    addedAt: DateTime.tryParse(m['addedAt'] as String? ?? '') ?? DateTime.now(),
    lastViewedAt: (m['lastViewedAt'] != null)
        ? DateTime.tryParse(m['lastViewedAt'] as String)
        : null,
  );

  LibraryItem copyWith({
    String? title,
    String? notes,
    List<String>? tags,
    String? kind,
    DateTime? lastViewedAt,
  }) =>
      LibraryItem(
        id: id,
        title: title ?? this.title,
        url: url,
        source: source,
        notes: notes ?? this.notes,
        tags: tags ?? List.of(this.tags),
        kind: kind ?? this.kind,
        addedAt: addedAt,
        lastViewedAt: lastViewedAt ?? this.lastViewedAt,
      );

  // Helpers export/import liste
  static String encodeList(List<LibraryItem> items) =>
      jsonEncode(items.map((e) => e.toJson()).toList());
  static List<LibraryItem> decodeList(String raw) {
    final List list = jsonDecode(raw) as List;
    return list.map((e) => LibraryItem.fromJson(e as Map<String, dynamic>)).toList();
  }
}