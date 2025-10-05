import 'dart:async';
import 'package:flutter/material.dart';
import 'home_tabs.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeTabs()),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFFFF9500);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.music_note, size: 72, color: accent),
            SizedBox(height: 16),
            Text(
              'MusicLooper',
              style: TextStyle(
                  color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800),
            ),
            SizedBox(height: 6),
            Text(
              'by Patperoni',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}