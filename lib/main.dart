import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:async';

import 'package:musiclooper_clean/screens/backing_player_screen.dart';
import 'screens/unified_player_beta.dart';
import 'screens/tools_screen.dart';
import 'screens/atelier_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // --- Gestion du partage Android ---
  String? sharedText;
  if (Platform.isAndroid) {
    const channel = MethodChannel('app.channel.shared.data');
    sharedText = await channel.invokeMethod<String>('getSharedText');
  }

  runApp(LoopTrainerApp(initialSharedText: sharedText));
}

class LoopTrainerApp extends StatelessWidget {
  final String? initialSharedText;
  const LoopTrainerApp({super.key, this.initialSharedText});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MusicLooper',
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
      home: HomeShell(initialSharedText: initialSharedText),
    );
  }
}

/// Shell principal avec onglets
class HomeShell extends StatefulWidget {
  final String? initialSharedText;
  const HomeShell({super.key, this.initialSharedText});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tabIndex = 0;

  late final UnifiedPlayerBeta _player = UnifiedPlayerBeta(
    initialYoutubeUrl: widget.initialSharedText,
  );

  late final AtelierScreen _atelier = AtelierScreen(
    initialSharedUrl: widget.initialSharedText,
  );

  late final List<Widget> _pages = [
    _player,
    const BackingPlayerScreen(),
    const ToolsScreen(),
    _atelier,
  ];

  @override
  void initState() {
    super.initState();
    if (widget.initialSharedText != null &&
        widget.initialSharedText!.contains('youtu')) {
      // si l'app est ouverte depuis un partage YouTube, aller direct à Atelier
      _tabIndex = 3;
    }
  }

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
          BottomNavigationBarItem(
              icon: Icon(Icons.smart_display), label: 'Player+YT'),
          BottomNavigationBarItem(
              icon: Icon(Icons.library_music), label: 'Backing'),
          BottomNavigationBarItem(icon: Icon(Icons.build), label: 'Outils'),
          BottomNavigationBarItem(
              icon: Icon(Icons.collections_bookmark), label: 'Atelier'),
        ],
      ),
    );
  }
}