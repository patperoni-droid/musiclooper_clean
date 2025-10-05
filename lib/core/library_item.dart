import 'dart:convert';

class LibraryItem {
  final String id;
  final String title;
  final String url;
  /// 'youtube' | 'local' (ou autre si tu ajoutes des types)
  final String source;
  final String? notes;
  final DateTime createdAt;

  LibraryItem({
    required this.id,
    required this.title,
    required this.url,
    required this.source,
    this.notes,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'url': url,
    'source': source,
    'notes': notes,
    'createdAt': createdAt.toIso8601String(),
  };

  factory LibraryItem.fromMap(Map<String, dynamic> m) => LibraryItem(
    id: m['id'] as String,
    title: m['title'] as String,
    url: m['url'] as String,
    source: m['source'] as String,
    notes: m['notes'] as String?,
    createdAt: DateTime.tryParse(m['createdAt'] as String? ?? '') ?? DateTime.now(),
  );

  String toJson() => jsonEncode(toMap());
  factory LibraryItem.fromJson(String s) => LibraryItem.fromMap(jsonDecode(s) as Map<String, dynamic>);
}