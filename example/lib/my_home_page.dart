import 'package:fintech_card_core/fintech_card_core.dart';
import 'package:fintech_card_core/fintech_card_core_platform_interface.dart';
import 'package:flutter/material.dart';

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {

  CardReaderController cardReaderController = CardReaderController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Home Page'),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            SmartCardInput(
              controller: cardReaderController,
              showNfcButton: true,
              scheme: CardInputScheme.humoAndUzcard,
            ),
            Divider(),

            ElevatedButton(
              onPressed: () {
                NfcScanDialog.show(context, controller: cardReaderController);
              },
              child: Center(child: Text('NFC')),
            ),
            Divider(),

            ElevatedButton(
              onPressed: () async {
                var a = await NfcScanDialog.show(
                  context,
                  controller: cardReaderController,
                  theme: NfcScanDialogTheme(
                    cancelLabel: 'Bekor qilish',
                    iconBuilder: (status, pulse) {
                      return Center();
                    },
                    scanningIcon: Icons.file_copy
                  ),
                );
                if (a != null) {
                  print(a.props);
                  print(a.pan);
                  print(a.cardType);
                  print(a.timestamp);
                  print(a.cardholderName);
                }
              },
              child: Center(child: Text('NFC custom dialog')),
            ),
          ],
        )
      ),
    );
  }
}
