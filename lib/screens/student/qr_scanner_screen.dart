import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';

class QRScannerScreen extends StatefulWidget {
  const QRScannerScreen({super.key});

  @override
  State<QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<QRScannerScreen> {
  final MobileScannerController cameraController = MobileScannerController();
  bool _isProcessing = false;

  Future<void> _handleScan(BarcodeCapture capture) async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    final List<Barcode> barcodes = capture.barcodes;
    if (barcodes.isNotEmpty) {
      final String code = barcodes.first.rawValue ?? '';
      if (code.isNotEmpty) {
        // Expected format: BUS101_2026-07-23
        final parts = code.split('_');
        if (parts.length == 2) {
          final busId = parts[0];
          final dateStr = parts[1];
          await _logAttendance(busId, dateStr);
        } else {
          _showError('Invalid QR Code format.');
        }
      }
    }
  }

  Future<void> _logAttendance(String busId, String dateStr) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final studentId = prefs.getString('studentRollNo') ?? 'UnknownRollNo';
      final studentName = prefs.getString('studentName') ?? 'UnknownStudent';
      final studentDept = prefs.getString('studentDept') ?? 'UnknownDept';
      final studentYear = prefs.getString('studentYear') ?? 'UnknownYear';
      final studentPic = prefs.getString('profilePicUrl') ?? '';
      
      final dbRef = FirebaseDatabase.instance.ref();
      
      // Check if already scanned
      final snapshot = await dbRef.child('attendance').child(dateStr).child(busId).child(studentId).get();
      if (snapshot.exists) {
        _showError('You have already scanned the bus pass for today!');
        return;
      }
      
      final timestamp = DateTime.now().toIso8601String();
      
      await dbRef.child('attendance').child(dateStr).child(busId).child(studentId).set({
        'name': studentName,
        'department': studentDept,
        'year': studentYear,
        'photoUrl': studentPic,
        'timestamp': timestamp,
        'status': 'boarded'
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Attendance logged successfully!'), backgroundColor: Colors.green),
        );
        Navigator.pop(context); // Go back after success
      }
    } catch (e) {
      _showError('Failed to log attendance: $e');
    }
  }


  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
      setState(() => _isProcessing = false);
      // Wait a moment before allowing next scan
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _isProcessing = false);
      });
    }
  }

  @override
  void dispose() {
    cameraController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan Bus Pass'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: cameraController,
            onDetect: _handleScan,
          ),
          if (_isProcessing)
            Container(
              color: Colors.black54,
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),
        ],
      ),
    );
  }
}
