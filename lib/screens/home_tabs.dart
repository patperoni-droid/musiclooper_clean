import 'package:flutter/material.dart';
import 'player_screen.dart';
import 'editor_screen.dart';
import 'tuner_screen.dart';
import 'metronome_screen.dart';

class HomeTabs extends StatefulWidget {
  const HomeTabs({super.key});

  @override
  State<HomeTabs> createState() => _HomeTabsState();
}

class _HomeTabsState extends State<HomeTabs> {
  int _index = 0;

  // On instancie UNE FOIS chaque page, et on les garde.
  final List<Widget> _pages = const [
    PlayerScreen(),
    EditorScreen(),
    TunerScreen(),
    MetronomeScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // IMPORTANT: garde toutes les pages montées
      body: IndexedStack(
        index: _index,
        children: _pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        backgroundColor: Colors.black,
        selectedItemColor: const Color(0xFFFF9500),
        unselectedItemColor: Colors.white70,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.play_circle_fill),
            label: 'Player',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.edit),
            label: 'Editor',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.music_note),
            label: 'Accordeur',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.av_timer),
            label: 'Métronome',
          ),
        ],
      ),
    );
  }
}