import 'package:flutter/material.dart';
import '../core/library_service.dart';
import '../core/library_item.dart';

import 'unified_player_beta.dart';
import 'backing_player_screen.dart';

enum _SortMode { recent, title, viewed }

class AtelierScreen extends StatefulWidget {
  final String? initialSharedUrl;
  const AtelierScreen({super.key, this.initialSharedUrl});

  @override
  State<AtelierScreen> createState() => _AtelierScreenState();
}

class _AtelierScreenState extends State<AtelierScreen> {
  final _svc = LibraryService(); // ✅ singleton
  late Future<List<LibraryItem>> _future;

  final _searchCtrl = TextEditingController();
  _SortMode _sort = _SortMode.recent;

  @override
  void initState() {
    super.initState();
    _future = _svc.getAll();
    _svc.changes.addListener(_refresh);

    // ✅ si l'app est ouverte via "Partager → MusicLooper"
    final shared = widget.initialSharedUrl?.trim();
    if (shared != null && shared.isNotEmpty && shared.contains('youtu')) {
      _svc.addFromUrl(shared).then((_) => _refresh());
    }
  }

  @override
  void dispose() {
    _svc.changes.removeListener(_refresh);
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _future = _svc.getAll());
    await _future;
  }

  // ---------- Ajouter une URL ----------
  Future<void> _addQuick() async {
    final urlCtrl = TextEditingController();
    final titleCtrl = TextEditingController();

    Future<void> _submit() async {
      final url = urlCtrl.text.trim();
      if (url.isEmpty) return;
      await _svc.addFromUrl(url, title: titleCtrl.text.trim()); // ✅ utilise addFromUrl
      if (mounted) Navigator.pop(context, true);
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF161616),
        title: const Text('Ajouter une vidéo YouTube', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlCtrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'URL YouTube',
                labelStyle: TextStyle(color: Colors.white70),
              ),
              onSubmitted: (_) => _submit(), // ✅ ENTER valide
            ),
            const SizedBox(height: 8),
            TextField(
              controller: titleCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Titre (facultatif)',
                labelStyle: TextStyle(color: Colors.white70),
              ),
              onSubmitted: (_) => _submit(), // ✅ ENTER valide
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: ()=> Navigator.pop(context, false), child: const Text('Annuler')),
          ElevatedButton(onPressed: _submit, child: const Text('Ajouter')),
        ],
      ),
    );

    if (ok == true) {
      await _refresh(); // ✅ rafraîchissement immédiat
    }
  }

  Future<void> _editNotes(LibraryItem it) async {
    final controller = TextEditingController(text: it.notes);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF161616),
        title: const Text('Notes', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          maxLines: 6,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(hintText: 'Ton mémo ici...'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Enregistrer')),
        ],
      ),
    );
    if (ok == true) {
      await _svc.updateNotes(it.id, controller.text.trim());
      _refresh();
    }
  }

  Future<void> _rename(LibraryItem it) async {
    final ctrl = TextEditingController(text: it.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF161616),
        title: const Text('Renommer', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(onPressed: ()=> Navigator.pop(context, false), child: const Text('Annuler')),
          ElevatedButton(onPressed: ()=> Navigator.pop(context, true), child: const Text('OK')),
        ],
      ),
    );
    if (ok == true) {
      await _svc.updateTitle(it.id, ctrl.text.trim());
      _refresh();
    }
  }

  Future<void> _delete(LibraryItem it) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Supprimer'),
        content: Text('Supprimer « ${it.title} » ?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Supprimer')),
        ],
      ),
    );
    if (ok == true) {
      await _svc.removeById(it.id);
      _refresh();
    }
  }

  Future<void> _openInPlayer(LibraryItem it) async {
    await _svc.touchViewed(it.id);
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => UnifiedPlayerBeta(initialYoutubeUrl: it.url),
    ));
  }

  void _openIn(LibraryItem it) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF171717),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.smart_display, color: Colors.white),
              title: const Text('Ouvrir dans Player+YT', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(context, 'unified'),
            ),
            ListTile(
              leading: const Icon(Icons.library_music, color: Colors.white),
              title: const Text('Ouvrir dans Backing Player', style: TextStyle(color: Colors.white)),
              subtitle: const Text('Marqueurs à la volée', style: TextStyle(color: Colors.white70)),
              onTap: () => Navigator.pop(context, 'backing'),
            ),
          ],
        ),
      ),
    );

    if (choice == 'backing') {
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => BackingPlayerScreen(initialYoutubeUrl: it.url),
      ));
    } else if (choice == 'unified') {
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => UnifiedPlayerBeta(initialYoutubeUrl: it.url),
      ));
    }
  }

  // ---------- Tri & Filtre ----------
  List<LibraryItem> _applySortFilter(List<LibraryItem> src) {
    final q = _searchCtrl.text.trim().toLowerCase();
    var list = src.where((e) {
      if (q.isEmpty) return true;
      final t = e.title.toLowerCase();
      final u = e.url.toLowerCase();
      final n = e.notes.toLowerCase();
      return t.contains(q) || u.contains(q) || n.contains(q);
    }).toList();

    switch (_sort) {
      case _SortMode.recent:
        list.sort((a, b) => b.addedAt.compareTo(a.addedAt));
        break;
      case _SortMode.title:
        list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        break;
      case _SortMode.viewed:
        list.sort((a, b) {
          final av = a.lastViewedAt ?? a.addedAt;
          final bv = b.lastViewedAt ?? b.addedAt;
          return bv.compareTo(av);
        });
        break;
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Atelier'),
        centerTitle: true,
        actions: [
          PopupMenuButton<_SortMode>(
            tooltip: 'Trier',
            onSelected: (m) => setState(() => _sort = m),
            itemBuilder: (c) => const [
              PopupMenuItem(value: _SortMode.recent, child: Text('Ajout récent')),
              PopupMenuItem(value: _SortMode.title,  child: Text('Titre A→Z')),
              PopupMenuItem(value: _SortMode.viewed, child: Text('Vus récemment')),
            ],
            icon: const Icon(Icons.sort),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addQuick,
        icon: const Icon(Icons.add),
        label: const Text('Ajouter'),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<LibraryItem>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final items = _applySortFilter(snap.data ?? const []);
            if (items.isEmpty) {
              return ListView(
                children: const [
                  SizedBox(height: 120),
                  Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        "Aucune vidéo.\nAjoute avec le bouton « + » ou depuis le Player YouTube.",
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              );
            }

            return Column(
              children: [
                // Recherche
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Rechercher (titre, URL, notes)…',
                      filled: true,
                      fillColor: const Color(0xFF1A1A1A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Colors.white24),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final it = items[i];
                      return ListTile(
                        onTap: () => _openIn(it),
                        leading: const Icon(Icons.play_circle_outline),
                        title: Text(it.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          it.url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white60),
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'notes') _editNotes(it);
                            if (v == 'rename') _rename(it);
                            if (v == 'delete') _delete(it);
                          },
                          itemBuilder: (c) => const [
                            PopupMenuItem(value: 'notes',  child: Text('Éditer les notes')),
                            PopupMenuItem(value: 'rename', child: Text('Renommer')),
                            PopupMenuItem(value: 'delete', child: Text('Supprimer')),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}