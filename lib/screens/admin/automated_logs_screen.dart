import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../models/log_entry.dart';
import '../../config/lang_config.dart';

class AutomatedLogsScreen extends StatefulWidget {
  final String currentLang;

  const AutomatedLogsScreen({
    Key? key,
    required this.currentLang,
  }) : super(key: key);

  @override
  _AutomatedLogsScreenState createState() => _AutomatedLogsScreenState();
}

class _AutomatedLogsScreenState extends State<AutomatedLogsScreen> {
  DateTime _selectedDate = DateTime.now();
  List<LogEntry> _logs = [];
  bool _isLoading = false;

  String t(String key) {
    String? val = appLang[widget.currentLang]?[key];
    if (val == null && widget.currentLang == 'ta') {
      val = appLang['ta_added']?[key];
    }
    return val ?? appLang['en']?[key] ?? key;
  }

  @override
  void initState() {
    super.initState();
    _fetchLogsForDate(_selectedDate);
  }

  String _formatDate(DateTime date) {
    return date.toIso8601String().substring(0, 10);
  }

  Future<void> _fetchLogsForDate(DateTime date) async {
    setState(() {
      _isLoading = true;
      _logs = [];
    });

    final String dateString = _formatDate(date);
    try {
      final snapshot = await FirebaseDatabase.instance.ref('arrival_logs/$dateString').get();
      if (snapshot.exists && snapshot.value != null) {
        final data = snapshot.value as Map;
        final List<LogEntry> loadedLogs = [];
        data.forEach((key, val) {
          if (val is Map) {
            double timestamp = (val['timestamp'] as num?)?.toDouble() ?? DateTime.now().millisecondsSinceEpoch.toDouble();
            
            // Only add to logs if the bus actually arrived today
            if (val['arrived'] != null) {
              loadedLogs.add(LogEntry(
                id: timestamp,
                bus: val['bus'] ?? key,
                driver: val['driver'] ?? 'Unknown',
                route: val['route'] ?? 'Unknown',
                date: val['date'] ?? dateString,
                arrived: val['arrived'],
                departed: val['departed'],
                status: val['status'] ?? 'arrived',
              ));
            }
          }
        });
        
        loadedLogs.sort((a, b) => b.id.compareTo(a.id));
        
        setState(() {
          _logs = loadedLogs;
        });
      }
    } catch (e) {
      debugPrint("Error fetching logs: $e");
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2023),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF2563EB),
              onPrimary: Colors.white,
              onSurface: Colors.black,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null && picked != _selectedDate) {
      setState(() {
        _selectedDate = picked;
      });
      _fetchLogsForDate(picked);
    }
  }

  Future<void> _exportCsv() async {
    if (_logs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No logs to export")));
      return;
    }

    List<List<dynamic>> rows = [];
    rows.add(["Bus", "Route", "Driver", "Arrival", "Departed", "Date"]);
    for (var log in _logs) {
      rows.add([
        log.bus,
        log.route,
        log.driver,
        log.arrived ?? "--",
        log.departed ?? "--",
        " ${_formatDate(_selectedDate)}",
      ]);
    }

    String csvData = Csv().encode(rows);

    try {
      if (kIsWeb) {
        await Printing.sharePdf(bytes: Uint8List.fromList(csvData.codeUnits), filename: 'bus_logs_${_formatDate(_selectedDate)}.csv');
      } else {
        final dir = await getApplicationDocumentsDirectory();
        final path = "${dir.path}/bus_logs_${_formatDate(_selectedDate)}.csv";
        final file = File(path);
        await file.writeAsString(csvData);
        
        await Printing.sharePdf(bytes: await file.readAsBytes(), filename: 'bus_logs_${_formatDate(_selectedDate)}.csv');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Export failed: $e")));
    }
  }

  Future<void> _exportPdf() async {
    if (_logs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No logs to export")));
      return;
    }

    final pdf = pw.Document();

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text("Panimalar Smart Transit - Automated Logs", style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 8),
              pw.Text("Date: ${_formatDate(_selectedDate)}", style: const pw.TextStyle(fontSize: 14)),
              pw.SizedBox(height: 20),
              pw.Table.fromTextArray(
                context: context,
                headers: ["Bus", "Route", "Driver", "Arrival", "Departed"],
                data: _logs.map((log) {
                  return [
                    log.bus,
                    log.route,
                    log.driver,
                    log.arrived ?? "--",
                    log.departed ?? "--",
                  ];
                }).toList(),
              ),
            ],
          );
        },
      ),
    );

    try {
      await Printing.sharePdf(bytes: await pdf.save(), filename: 'bus_logs_${_formatDate(_selectedDate)}.pdf');
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Export failed: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      appBar: AppBar(
        title: Text(t('📍 LOGS (${_formatDate(_selectedDate)})'), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black87),
        titleTextStyle: const TextStyle(color: Colors.black87),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_month, color: Color(0xFF2563EB)),
            onPressed: () => _selectDate(context),
            tooltip: "Select Date",
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.download, color: Color(0xFF2563EB)),
            onSelected: (value) {
              if (value == 'csv') {
                _exportCsv();
              } else if (value == 'pdf') {
                _exportPdf();
              }
            },
            itemBuilder: (BuildContext context) {
              return [
                const PopupMenuItem(
                  value: 'csv',
                  child: Row(
                    children: [
                      Icon(Icons.table_chart, color: Colors.green, size: 20),
                      SizedBox(width: 8),
                      Text("Download CSV"),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'pdf',
                  child: Row(
                    children: [
                      Icon(Icons.picture_as_pdf, color: Colors.red, size: 20),
                      SizedBox(width: 8),
                      Text("Download PDF"),
                    ],
                  ),
                ),
              ];
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _logs.isEmpty
              ? Center(
                  child: Text(
                    t('No automated logs for ${_formatDate(_selectedDate)}.'),
                    style: const TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.bold),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // Table Header
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(8),
                          topRight: Radius.circular(8),
                        ),
                      ),
                      child: Row(
                        children: const [
                          Expanded(flex: 2, child: Text('BUS', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.black87, fontSize: 12, letterSpacing: 0.5))),
                          Expanded(flex: 3, child: Text('ARRIVAL', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.black87, fontSize: 12, letterSpacing: 0.5))),
                          Expanded(flex: 3, child: Text('DEPARTED', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.black87, fontSize: 12, letterSpacing: 0.5))),
                        ],
                      ),
                    ),
                    // Table Rows
                    Container(
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(color: Colors.grey.shade300),
                          right: BorderSide(color: Colors.grey.shade300),
                          bottom: BorderSide(color: Colors.grey.shade300),
                        ),
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(8),
                          bottomRight: Radius.circular(8),
                        ),
                      ),
                      child: Column(
                        children: _logs.map((log) {
                          int index = _logs.indexOf(log);
                          bool isLast = index == _logs.length - 1;
                          return Container(
                            decoration: BoxDecoration(
                              color: index % 2 == 0 ? Colors.white : Colors.grey.shade50,
                              border: isLast ? null : Border(bottom: BorderSide(color: Colors.grey.shade200)),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            child: Row(
                              children: [
                                Expanded(flex: 2, child: Text(log.bus, style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.black87))),
                                Expanded(flex: 3, child: Text(log.arrived ?? '--', style: TextStyle(fontWeight: FontWeight.w500, color: log.arrived != null ? Colors.black87 : Colors.grey))),
                                Expanded(flex: 3, child: Text(log.departed ?? '--', style: TextStyle(fontWeight: FontWeight.w500, color: log.departed != null ? Colors.black87 : Colors.grey))),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
    );
  }
}
