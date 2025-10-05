// lib/screens/tools_screen.dart
import 'package:flutter/material.dart';
import 'tuner_screen.dart';
import 'metronome_screen.dart';

class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          // Onglets
          Material(
            color: Colors.black,
            child: const TabBar(
              tabs: [
                Tab(icon: Icon(Icons.music_note), text: 'Tuner'),
                Tab(icon: Icon(Icons.timer), text: 'Métronome'),
              ],
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white54,
              indicatorColor: Colors.orangeAccent,
            ),
          ),
          // Contenu des onglets
          const Expanded(
            child: TabBarView(
              children: [
                TunerScreen(),
                MetronomeScreen(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}