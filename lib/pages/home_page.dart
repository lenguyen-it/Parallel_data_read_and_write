import 'package:flutter/material.dart';
import 'package:paralled_data/pages/history_page.dart';
import 'package:paralled_data/rfid_bluetooth_connect.dart';
import 'package:paralled_data/rfid_test_connect.dart';
import 'barcode_scan_page.dart';
import 'rfid_scan_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Paralled Data'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.qr_code_2,
                    size: 100, color: Colors.blueAccent),
                const SizedBox(height: 40),

                // Nút quét QR / Barcode
                ElevatedButton.icon(
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Quét QR / Barcode'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.lightBlue,
                    minimumSize: const Size(double.infinity, 60),
                    textStyle: const TextStyle(fontSize: 18),
                  ),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const BarcodeScanPage(),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 20),

                // Nút quét RFID
                ElevatedButton.icon(
                  icon: const Icon(Icons.nfc),
                  label: const Text('Quét RFID (UHF)'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 60),
                    backgroundColor: Colors.green,
                    textStyle: const TextStyle(fontSize: 18),
                  ),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const RfidScanPage(),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 20),

                // Nút lịch sử
                ElevatedButton.icon(
                  icon: const Icon(Icons.history),
                  label: const Text('Lịch sử quét'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 60),
                    backgroundColor: Colors.orange,
                    textStyle: const TextStyle(fontSize: 18),
                  ),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const HistoryPage()),
                    );
                  },
                ),

                const SizedBox(height: 50),

                // Nút test quét
                ElevatedButton.icon(
                  icon: const Icon(Icons.bug_report),
                  label: const Text('Test quét'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 60),
                    textStyle:
                        const TextStyle(fontSize: 18, color: Colors.white),
                  ),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const RfidTestConnect()),
                    );
                  },
                ),

                const SizedBox(height: 20),

                // ElevatedButton.icon(
                //   icon: const Icon(Icons.bug_report),
                //   label: const Text('Test bluetooth'),
                //   style: ElevatedButton.styleFrom(
                //     minimumSize: const Size(double.infinity, 60),
                //     textStyle:
                //         const TextStyle(fontSize: 18, color: Colors.white),
                //   ),
                //   onPressed: () {
                //     Navigator.push(
                //       context,
                //       MaterialPageRoute(builder: (_) => RfidDemoPage()),
                //     );
                //   },
                // ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
