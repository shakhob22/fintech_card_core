import 'package:fintech_card_core/fintech_card_core.dart';
import 'package:fintech_card_core_example/my_home_page.dart';
import 'package:flutter/material.dart';

import 'pages/manual_page.dart';
import 'pages/mock_page.dart';
import 'pages/nfc_page.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'fintech_card_core demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      // home: const HomePage(),
      home: const MyHomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _controller = CardReaderController();
  int _selectedTab = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      NfcPage(controller: _controller),
      ManualPage(controller: _controller),
      MockPage(controller: _controller),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('fintech_card_core'),
        centerTitle: true,
      ),
      body: tabs[_selectedTab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTab,
        onDestinationSelected: (i) => setState(() => _selectedTab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.nfc_outlined),
            selectedIcon: Icon(Icons.nfc),
            label: 'NFC',
          ),
          NavigationDestination(
            icon: Icon(Icons.keyboard_outlined),
            selectedIcon: Icon(Icons.keyboard),
            label: 'Manual',
          ),
          NavigationDestination(
            icon: Icon(Icons.science_outlined),
            selectedIcon: Icon(Icons.science),
            label: 'Mock',
          ),
        ],
      ),
    );
  }
}
