import 'package:flutter/material.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'library_store.dart';
import 'unified_player_beta.dart'; // <- ton fichier existant

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<LibraryItem> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final items = await LibraryStore.load();
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  void _play(LibraryItem it) {
    final id = YoutubePlayer.convertUrlToId(it.url);
    if (id == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('URL YouTube invalide')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UnifiedPlayerBeta(initialYoutubeUrl: it.url),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Bibliothèque'),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            tooltip: 'Vider',
            icon: const Icon(Icons.delete_sweep),
            onPressed: () async {
              await LibraryStore.clear();
              await _reload();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
          ? const Center(
          child: Text('Aucun lien pour le moment.\nPartage un lien YouTube vers l’app.',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.white70)))
          : ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
        itemBuilder: (ctx, i) {
          final it = _items[i];
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            title: Text(
              it.title ?? it.url,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              it.addedAt.toLocal().toString(),
              style: const TextStyle(color: Colors.white54),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Lire',
                  icon: const Icon(Icons.play_arrow, color: Colors.white),
                  onPressed: () => _play(it),
                ),
                IconButton(
                  tooltip: 'Supprimer',
                  icon: const Icon(Icons.delete_outline, color: Colors.white70),
                  onPressed: () async {
                    await LibraryStore.remove(it.id);
                    await _reload();
                  },
                ),
              ],
            ),
            onTap: () => _play(it),
          );
        },
      ),
    );
  }
}