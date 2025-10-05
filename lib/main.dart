import 'package:flutter/material.dart';

// Écrans
import 'screens/unified_player_beta.dart';
import 'screens/backing_track_screen.dart';
import 'screens/tools_screen.dart';

// NOUVEAU : Atelier (bibliothèque)
import 'screens/atelier_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LoopTrainerApp());
}

class LoopTrainerApp extends StatelessWidget {
  const LoopTrainerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LoopTrainer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Color(0xFF101010),
          selectedItemColor: Colors.orangeAccent,
          unselectedItemColor: Colors.white54,
          type: BottomNavigationBarType.fixed,
        ),
      ),
      // On conserve ton démarrage direct sur les onglets
      home: const HomeShell(),
    );
  }
}

/// Shell principal avec onglets
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tabIndex = 0;

  // 4 pages : Player+YT, Backing, Outils, Atelier
  late final List<Widget> _pages = const [
    UnifiedPlayerBeta(),    // Player unifié (Local + YouTube)
    BackingTrackScreen(),   // Backing tracks
    ToolsScreen(),          // Outils (Tuner + Métronome)
    AtelierScreen(),        // Atelier / Bibliothèque
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: IndexedStack(
          index: _tabIndex,
          children: _pages,
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tabIndex,
        onTap: (i) => setState(() => _tabIndex = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.smart_display),   label: 'Player+YT'),
          BottomNavigationBarItem(icon: Icon(Icons.library_music),   label: 'Backing'),
          BottomNavigationBarItem(icon: Icon(Icons.build),           label: 'Outils'),
          BottomNavigationBarItem(icon: Icon(Icons.collections_bookmark), label: 'Atelier'),
        ],
      ),
    );
  }
}