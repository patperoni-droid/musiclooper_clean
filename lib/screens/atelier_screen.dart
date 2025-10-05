import 'package:flutter/material.dart';
import '../core/library_service.dart';
import '../core/library_item.dart';
import 'unified_player_beta.dart';

class AtelierScreen extends StatefulWidget {
  const AtelierScreen({super.key});

  @override
  State<AtelierScreen> createState() => _AtelierScreenState();
}

class _AtelierScreenState extends State<AtelierScreen> {
  final _svc = LibraryService();
  late Future<List<LibraryItem>> _future;

  @override
  void initState() {
    super.initState();
    _future = _svc.getAll();

    // 👉 écouter les changements (ajout/suppression/màj) pour rafraîchir
    _svc.changes.addListener(_refresh);
  }

  @override
  void dispose() {
    _svc.changes.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _future = _svc.getAll();
    });
    await _future;
  }

  Future<void> _editNotes(LibraryItem it) async {
    final controller = TextEditingController(text: it.notes ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Notes'),
        content: TextField(
          controller: controller,
          maxLines: 6,
          decoration: const InputDecoration(hintText: 'Ton mémo ici...'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Enregistrer')),
        ],
      ),
    );
    if (ok == true) {
      await _svc.updateNotes(it.id, controller.text);
      _refresh();
    }
  }

  Future<void> _delete(LibraryItem it) async {
    await _svc.removeById(it.id);
    _refresh();
  }

  void _openInPlayer(LibraryItem it) {
    // Ouvre le Player YouTube avec l’URL de l’élément
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => UnifiedPlayerBeta(initialYoutubeUrl: it.url),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Atelier'),
        centerTitle: true,
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<LibraryItem>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final items = snap.data ?? const <LibraryItem>[];
            if (items.isEmpty) {
              return const Center(
                child: Text(
                  "Aucune vidéo enregistrée pour l’instant.\nAjoute depuis le Player YouTube avec le bouton « Enregistrer ».",
                  textAlign: TextAlign.center,
                ),
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final it = items[i];
                return Dismissible(
                  key: ValueKey(it.id),
                  background: Container(
                    color: Colors.redAccent.withOpacity(0.9),
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  direction: DismissDirection.endToStart,
                  confirmDismiss: (_) async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Supprimer'),
                        content: Text('Supprimer « ${it.title} » ?'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Annuler')),
                          ElevatedButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Supprimer')),
                        ],
                      ),
                    );
                    return ok ?? false;
                  },
                  onDismissed: (_) => _delete(it),
                  child: ListTile(
                    leading: IconButton(
                      tooltip: 'Lire',
                      icon: const Icon(Icons.play_arrow),
                      onPressed: () => _openInPlayer(it),
                    ),
                    title: Text(it.title,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      it.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white60),
                    ),
                    trailing: Wrap(
                      spacing: 8,
                      children: [
                        Chip(
                          label: Text(it.source),
                          backgroundColor: Colors.white12,
                        ),
                        IconButton(
                          tooltip: 'Notes',
                          icon: const Icon(Icons.edit_note),
                          onPressed: () => _editNotes(it),
                        ),
                      ],
                    ),
                    onTap: () => _openInPlayer(it),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}