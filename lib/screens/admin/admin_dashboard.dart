import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_storage/firebase_storage.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/driver_entry.dart';
import '../../models/route_entry.dart';
import '../../models/log_entry.dart';
import '../../models/alert_entry.dart';
import '../../models/upload_entry.dart';
import '../../models/bus_sim_state.dart';
import '../../config/routes_config.dart';
import '../../config/lang_config.dart';
import '../../widgets/custom_charts.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../driver/bus_card_icons.dart';
import 'automated_logs_screen.dart';
class AdminDashboard extends StatefulWidget {
  final VoidCallback onSwitchRole;
  final String currentLang;
  final Function(String) onLanguageChanged;
  const AdminDashboard({super.key, required this.onSwitchRole, required this.currentLang, required this.onLanguageChanged});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  String t(String key) {
    String? val = appLang[widget.currentLang]?[key];
    if (val == null && widget.currentLang == 'ta') {
      val = appLang['ta_added']?[key];
    }
    return val ?? appLang['en']?[key] ?? key;
  }

  // Navigation & tabs
  int _currentTab = 0;

  // Firebase pickup requests queue
  List<Map<String, dynamic>> _requests = [];
  bool _isLoadingRequests = true;
  StreamSubscription? _requestsSub;

  // Persistence State Lists
  List<DriverEntry> _drivers = [];
  List<RouteEntry> _routes = [];
  List<LogEntry> _logs = [];
  List<LogEntry> _arrivalLogs = [];
  StreamSubscription? _arrivalLogsSub;
  List<AlertEntry> _alerts = [];
  List<Map<String, dynamic>> _specialBuses = [];
  StreamSubscription? _specialBusesSub;
  List<Map<String, dynamic>> _adminBreakdownsList = [];
  int _adminUnreadCount = 0;
  List<UploadEntry> _uploads = [];

  // Admin STT Intercom State
  Map<String, List<Map<String, dynamic>>> _adminIntercomMessages = {};
  StreamSubscription? _adminIntercomSub;
  final bool _isAdminSttListening = false;
  final String _selectedAdminSttLang = 'en';
  final TextEditingController _adminChatInputCtrl = TextEditingController();

  // Per-bus unread message count (WhatsApp-style badge)
  Map<String, int> _unreadPerBus = {};
  // Last seen message timestamp per bus (key: bus number)
  Map<String, int> _lastSeenTimestamp = {};

  // WhatsApp Style Intercom UI State
  String? _selectedIntercomBus;
  final TextEditingController _intercomSearchCtrl = TextEditingController();
  String _intercomSearchQuery = "";
  final ScrollController _chatScrollController = ScrollController();

  bool _isRecordingVoice = false;
  int _recordingDurationSecs = 0;
  Timer? _recordingTimer;
  List<double> _recordingWaveforms = [];
  String? _playingMsgId;
  double _playbackProgress = 0.0;
  Timer? _playbackTimer;
  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final FlutterTts _flutterTts = FlutterTts();

  // For language selection
  String _currentLanguageCode = 'en';

  void _speakTamilReason(String text) async {
    await _flutterTts.setLanguage("ta-IN");
    await _flutterTts.setPitch(1.0);
    await _flutterTts.speak(text);
  }
  String? _recordPath;

  // Live Bus Locations
  Map<String, Map<String, dynamic>> _liveBuses = {};
  StreamSubscription? _liveLocationsSub;
  final Map<String, Map<String, dynamic>> _firebaseBreakdowns = {};
  StreamSubscription? _breakdownListenerSub;
  final Map<String, Map<String, dynamic>> _driversAlerts = {};
  StreamSubscription? _driversAlertsSub;
  StreamSubscription? _breakdownAlertsSub;

  // Map Controllers
  final MapController _mapController = MapController();

  // Registry sub-toggle
  int _registryViewMode = 0; // 0 = Drivers, 1 = Routes
  final TextEditingController _adminRouteSearchCtrl = TextEditingController();
  String _adminRouteSearchQuery = "";
  String _liveMapSearchQuery = "";
  String _driverRegistrySearchQuery = "";

  // Live map search
  final TextEditingController _liveMapSearchCtrl = TextEditingController();
  RouteEntry? _selectedLiveRoute;
  bool _hasInitialMapAutoZoomed = false;

  // Logs Filter
  final String _selectedLogDate = DateTime.now().toIso8601String().substring(0, 10);

  // Stop Capture State
  bool _allowDriversToAddStops = false;
  StreamSubscription? _adminSettingsSub;
  List<Map<String, dynamic>> _newStops = [];
  StreamSubscription? _newStopsSub;

  // Constants & Static Caches
  final LatLng _campusCoord = const LatLng(13.0489049, 80.0754642);

  final List<String> _routeColors = [
    '#2563EB', '#22C55E', '#F97316', '#DB2777', '#8B5CF6', '#06B6D4', '#EF4444', '#84CC16', '#F59E0B', '#10B981'
  ];

  // Cached route geometries (interpolated paths)
  final Map<String, List<LatLng>> _routeGeometries = {};

  @override
  void initState() {
    super.initState();
    _loadPersistedData();
    _listenForRequests();
    _listenForAdminIntercomMessages();
    _listenForLiveLocations();
    _listenForAdminSettings();
    _listenForNewStops();
    _listenForBreakdowns();
    _listenForArrivalLogs();
    _initAdminFcm();
  }

  // ─── FCM PUSH NOTIFICATIONS SETUP ────────────────────────────────────
  final FlutterLocalNotificationsPlugin _localNotif = FlutterLocalNotificationsPlugin();

  void _initAdminFcm() async {
    if (kIsWeb) return; // Web does not support background push via FCM device tokens
    try {
      // Request permission
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);

      // Setup local notification channel
      const androidChannel = AndroidNotificationChannel(
        'intercom_channel',
        'Intercom Messages',
        description: 'Driver intercom notifications',
        importance: Importance.max,
        playSound: true,
      );
      await _localNotif
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(androidChannel);

      await _localNotif.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
      );

      // Get FCM token and save to Firebase RTDB
      final token = await messaging.getToken();
      if (token != null && Firebase.apps.isNotEmpty) {
        await FirebaseDatabase.instance.ref('adminFcmToken').set(token);
        debugPrint('Admin FCM token saved: $token');
      }

      // Handle foreground messages — show local notification
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        final notif = message.notification;
        if (notif != null) {
          _localNotif.show(
            DateTime.now().millisecondsSinceEpoch ~/ 1000,
            notif.title,
            notif.body,
            const NotificationDetails(
              android: AndroidNotificationDetails(
                'intercom_channel',
                'Intercom Messages',
                importance: Importance.max,
                priority: Priority.high,
                playSound: true,
              ),
              iOS: DarwinNotificationDetails(),
            ),
          );
        }
      });
    } catch (e) {
      debugPrint('FCM init error: $e');
    }
  }

  @override
  void dispose() {
    _requestsSub?.cancel();
    _liveLocationsSub?.cancel();
    _adminIntercomSub?.cancel();
    _adminSettingsSub?.cancel();
    _specialBusesSub?.cancel();
    _newStopsSub?.cancel();
    _breakdownListenerSub?.cancel();
    _breakdownAlertsSub?.cancel();
    _arrivalLogsSub?.cancel();
    _adminChatInputCtrl.dispose();
    super.dispose();
  }

  // ─── PERSISTENCE DATA LOAD/SAVE ─────────────────────────────────
  void _loadPersistedData() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Restore persistent intercom last seen timestamps
    final keys = prefs.getKeys();
    for (final k in keys) {
      if (k.startsWith('intercom_last_seen_')) {
        final bus = k.replaceFirst('intercom_last_seen_', '');
        final val = prefs.getInt(k) ?? 0;
        _lastSeenTimestamp[bus] = val;
      }
    }

    // Drivers
    _drivers = [];
    final driversStr = prefs.getString('ptAdmin_drivers');
    if (driversStr != null) {
      try {
        final List decoded = json.decode(driversStr);
        _drivers = decoded
            .map((e) => DriverEntry.fromJson(e))
            .where((d) => d.driver.trim().isNotEmpty || d.bus.trim().isNotEmpty)
            .toList();
      } catch (_) {}
    }

    if (Firebase.apps.isNotEmpty) {
      FirebaseDatabase.instance.ref('drivers').onValue.listen((event) {
        if (event.snapshot.exists && event.snapshot.value != null) {
          final data = event.snapshot.value;
          List<DriverEntry> loadedDrivers = [];
          if (data is Map) {
            data.forEach((k, v) {
              if (v is Map) {
                final map = Map<String, dynamic>.from(v);
                final dName = map['driver']?.toString().trim() ?? '';
                final bNum = (map['bus']?.toString().trim() ?? '').isNotEmpty 
                    ? map['bus'].toString().trim() 
                    : k.toString().trim();
                // Only include if it has a driver name or valid bus/route configured
                if (dName.isNotEmpty || (map['route'] != null && map['route'].toString().trim().isNotEmpty)) {
                  map['bus'] = bNum;
                  loadedDrivers.add(DriverEntry.fromJson(map));
                }
              }
            });
          } else if (data is List) {
            for (var item in data) {
              if (item is Map) {
                final map = Map<String, dynamic>.from(item);
                final dName = map['driver']?.toString().trim() ?? '';
                if (dName.isNotEmpty) {
                  loadedDrivers.add(DriverEntry.fromJson(map));
                }
              }
            }
          }
          if (mounted) {
            setState(() {
              _drivers = loadedDrivers;
            });
          }
          prefs.setString('ptAdmin_drivers', json.encode(_drivers.map((e) => e.toJson()).toList()));
        } else {
          if (mounted) {
            setState(() {
              _drivers = [];
            });
          }
          prefs.setString('ptAdmin_drivers', json.encode([]));
        }
      });
    }

    // Routes
    if (Firebase.apps.isNotEmpty) {
      FirebaseDatabase.instance.ref('routes').onValue.listen((event) {
        if (event.snapshot.exists && event.snapshot.value != null) {
          final data = event.snapshot.value;
          List<RouteEntry> fbRoutes = [];
          void checkAndAdd(Map val) {
            final isDel = val['deleted'] == true || val['isDeleted'] == true || val['status'] == 'deleted';
            if (!isDel) {
              fbRoutes.add(RouteEntry.fromJson(Map<String, dynamic>.from(val)));
            }
          }

          if (data is Map) {
            data.forEach((k, val) {
              if (val is Map) {
                final mapVal = Map<String, dynamic>.from(val);
                if (mapVal['key'] == null || mapVal['key'].toString().isEmpty) {
                  mapVal['key'] = k.toString();
                }
                checkAndAdd(mapVal);
              }
            });
          } else if (data is List) {
            for (var val in data) {
              if (val != null && val is Map) checkAndAdd(val);
            }
          }
          if (mounted) {
            setState(() {
              _routes = fbRoutes;
              if (_selectedLiveRoute != null) {
                _selectedLiveRoute = _routes.firstWhere(
                  (r) => r.key.toLowerCase() == _selectedLiveRoute!.key.toLowerCase(),
                  orElse: () => _selectedLiveRoute!,
                );
              }
            });
          }
          prefs.setString('ptAdmin_routes', json.encode(_routes.map((e) => e.toJson()).toList()));
        } else {
          if (mounted) {
            setState(() {
              _routes = _getDefaultRoutes();
            });
          }
          _saveRoutes();
        }
      });

      FirebaseDatabase.instance.ref('stopLocations').onValue.listen((event) {
        if (event.snapshot.exists && event.snapshot.value != null) {
          final data = event.snapshot.value;
          if (data is Map) {
            data.forEach((key, val) {
              if (val is Map) {
                final lat = (val['lat'] as num?)?.toDouble();
                final lng = (val['lng'] as num?)?.toDouble();
                if (lat != null && lng != null) {
                  final cleanKey = key.toString().toLowerCase().trim();
                  _stopCoordsRegistry[cleanKey] = LatLng(lat, lng);
                }
              }
            });
            if (mounted) setState(() {});
          }
        }
      });
    } else {
      final routesStr = prefs.getString('ptAdmin_routes');
      if (routesStr != null) {
        try {
          final List decoded = json.decode(routesStr);
          _routes = decoded.map((e) => RouteEntry.fromJson(e)).toList();
        } catch (e) {
          _routes = _getDefaultRoutes();
        }
      } else {
        _routes = _getDefaultRoutes();
      }
    }

    // Logs
    final logsStr = prefs.getString('ptAdmin_logs');
    if (logsStr != null) {
      try {
        final List decoded = json.decode(logsStr);
        _logs = decoded.map((e) => LogEntry.fromJson(e)).toList();
      } catch (e) {
        _logs = _getDefaultLogs();
      }
    } else {
      _logs = _getDefaultLogs();
    }

    // Alerts
    final alertsStr = prefs.getString('ptAdmin_alerts');
    if (alertsStr != null) {
      try {
        final List decoded = json.decode(alertsStr);
        _alerts = decoded.map((e) => AlertEntry.fromJson(e)).toList();
      } catch (e) {
        _alerts = _getDefaultAlerts();
      }
    } else {
      _alerts = _getDefaultAlerts();
    }

    // Uploads
    final uploadsStr = prefs.getString('ptAdmin_uploads');
    if (uploadsStr != null) {
      try {
        final List decoded = json.decode(uploadsStr);
        _uploads = decoded.map((e) => UploadEntry.fromJson(e)).toList();
      } catch (e) {
        _uploads = [];
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _saveDrivers() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setString('ptAdmin_drivers', json.encode(_drivers.map((e) => e.toJson()).toList()));
    
    // Also sync to Firebase Realtime Database
    if (Firebase.apps.isNotEmpty) {
      try {
        final dbRef = FirebaseDatabase.instance.ref('drivers');
        final snap = await dbRef.get();
        Map<String, dynamic> existingData = {};
        if (snap.exists && snap.value != null) {
          final data = snap.value;
          if (data is Map) {
            existingData = Map<String, dynamic>.from(data);
          } else if (data is List) {
            for (var item in data) {
              if (item is Map && item['bus'] != null) {
                existingData[item['bus'].toString()] = Map<String, dynamic>.from(item);
              }
            }
          }
        }
        
        final Map<String, dynamic> newDriverMap = {};
        for (var d in _drivers) {
          final busKey = d.bus;
          if (existingData.containsKey(busKey)) {
            final oldEntry = existingData[busKey] as Map;
            oldEntry['driver'] = d.driver;
            oldEntry['bus'] = d.bus;
            oldEntry.remove('contact');
            oldEntry['route'] = d.route;
            oldEntry['type'] = d.type;
            oldEntry['id'] = d.id;
            newDriverMap[busKey] = oldEntry;
          } else {
            final dJson = d.toJson();
            dJson.remove('contact');
            newDriverMap[busKey] = dJson;
          }
        }
        
        await dbRef.set(newDriverMap);
      } catch (e) {
        debugPrint("Error syncing drivers to Firebase: $e");
      }
    }
  }

  List<String> healRouteStops(List<String> rawStops) {
    if (rawStops.isEmpty) return [];
    
    // Re-combine any split Lng: or orphan parenthesis fragments back into single stop strings
    final List<String> combined = [];
    for (int i = 0; i < rawStops.length; i++) {
      final s = rawStops[i].trim();
      if (s.isEmpty) continue;
      if ((s.startsWith("Lng:") || s == ")" || s == "),") && combined.isNotEmpty) {
        combined[combined.length - 1] = "${combined.last}, $s";
      } else {
        combined.add(s);
      }
    }
    
    // Preserve full stop strings (including driver captured Lat/Lng coordinates)
    final List<String> preservedStops = [];
    for (final s in combined) {
      if (s.trim().isNotEmpty) {
        preservedStops.add(s.trim());
      }
    }
    return preservedStops;
  }

  List<String> _parseRouteStops(String text) {
    if (text.trim().isEmpty) return [];
    final rawList = text.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
    return healRouteStops(rawList);
  }

  String _cleanStopName(String stop) {
    String name = stop.trim();
    if (name.contains("(Lat:")) {
      name = name.split("(Lat:")[0].trim();
    }
    name = name.replaceAll(RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)?'), '')
               .replaceAll(RegExp(r'\(Lat:[^)]*'), '')
               .replaceAll(RegExp(r'Lng:[^)]*'), '')
               .replaceAll(')', '')
               .trim();
    return name.isNotEmpty ? name : stop.trim();
  }

  Future<void> _instantDeleteStopFromDatabase(String routeKey, List<String> updatedStops) async {
    final cleanStops = healRouteStops(updatedStops);
    final idx = _routes.indexWhere((r) => r.key.toLowerCase() == routeKey.toLowerCase());
    if (idx != -1) {
      final updatedEntry = RouteEntry(
        id: _routes[idx].id,
        key: _routes[idx].key,
        name: _routes[idx].name,
        stops: cleanStops,
        color: _routes[idx].color,
      );
      _routes[idx] = updatedEntry;
      if (_selectedLiveRoute != null && _selectedLiveRoute!.key.toLowerCase() == routeKey.toLowerCase()) {
        _selectedLiveRoute = updatedEntry;
      }
    }
    
    final prefs = await SharedPreferences.getInstance();
    prefs.setString('ptAdmin_routes', json.encode(_routes.map((e) => e.toJson()).toList()));
    
    if (Firebase.apps.isNotEmpty) {
      try {
        await FirebaseDatabase.instance.ref('routes/$routeKey/stops').set(cleanStops);
        if (mounted) setState(() {});
        _showAppSnackBar("Stop deleted instantly from database.");
      } catch (e) {
        debugPrint("Error updating stops in Firebase: $e");
      }
    }
  }

  void _saveRoutes() async {
    // Sanitize and clean stops across all routes
    for (int i = 0; i < _routes.length; i++) {
      final cleanEntry = RouteEntry(
        id: _routes[i].id,
        key: _routes[i].key,
        name: _routes[i].name,
        stops: healRouteStops(_routes[i].stops),
        color: _routes[i].color,
      );
      _routes[i] = cleanEntry;
      if (_selectedLiveRoute != null && _selectedLiveRoute!.key.toLowerCase() == cleanEntry.key.toLowerCase()) {
        _selectedLiveRoute = cleanEntry;
      }
    }

    final prefs = await SharedPreferences.getInstance();
    prefs.setString('ptAdmin_routes', json.encode(_routes.map((e) => e.toJson()).toList()));
    
    // Sync each route individually to Firebase (do NOT replace the entire /routes node)
    if (Firebase.apps.isNotEmpty) {
      try {
        for (var r in _routes) {
          if (r.key.isEmpty) continue;
          final rRef = FirebaseDatabase.instance.ref('routes/${r.key}');
          final cleanStops = healRouteStops(r.stops);
          final rJson = r.toJson();
          rJson['stops'] = cleanStops;
          rJson['deleted'] = false;
          rJson['isDeleted'] = false;
          rJson['status'] = 'active';
          await rRef.set(rJson);
        }
      } catch (e) {
        debugPrint("Error syncing routes to Firebase: $e");
      }
    }
  }

  void _saveLogs() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setString('ptAdmin_logs', json.encode(_logs.map((e) => e.toJson()).toList()));
  }

  void _saveAlerts() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setString('ptAdmin_alerts', json.encode(_alerts.map((e) => e.toJson()).toList()));
  }

  void _saveUploads() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setString('ptAdmin_uploads', jsonEncode([])); // Keep empty if we don't have _uploads anymore
  }

  List<DriverEntry> _getDefaultDrivers() {
    return [];
  }

  List<RouteEntry> _getDefaultRoutes() {
    return [];
  }

  String _getRouteDisplayName(String routeKey) {
    if (routeKey.isEmpty) return "Unassigned";

    final cleanTarget = routeKey
        .toLowerCase()
        .replaceAll(RegExp(r'^[Bb]us\s*|^[Bb]'), '')
        .replaceAll('route_', '')
        .replaceAll('route', '')
        .replaceAll('_', '')
        .trim();

    // 1. Search in dynamic _routes list (Routes Registry)
    for (final r in _routes) {
      final cleanKey = r.key
          .toLowerCase()
          .replaceAll(RegExp(r'^[Bb]us\s*|^[Bb]'), '')
          .replaceAll('route_', '')
          .replaceAll('route', '')
          .replaceAll('_', '')
          .trim();
      if (r.key == routeKey || cleanKey == cleanTarget || r.name == routeKey) {
        return r.name;
      }
    }

    // 2. Search in routeLabelsConfig static map fallback
    if (routeLabelsConfig.containsKey(routeKey)) {
      return routeLabelsConfig[routeKey]!;
    }
    final altKey = 'route_$cleanTarget';
    if (routeLabelsConfig.containsKey(altKey)) {
      return routeLabelsConfig[altKey]!;
    }
    for (final entry in routeLabelsConfig.entries) {
      final k = entry.key
          .toLowerCase()
          .replaceAll(RegExp(r'^[Bb]us\s*|^[Bb]'), '')
          .replaceAll('route_', '')
          .replaceAll('route', '')
          .replaceAll('_', '')
          .trim();
      if (k == cleanTarget) {
        return entry.value;
      }
    }

    // 3. Clean fallback formatting
    if (cleanTarget.isNotEmpty && RegExp(r'^\d+$').hasMatch(cleanTarget)) {
      return "Route $cleanTarget";
    }
    return routeKey;
  }

  String _resolveSelectedRouteKey(String rawKey) {
    if (rawKey.isEmpty) {
      return _routes.isNotEmpty ? _routes.first.key : 'route_15';
    }
    if (_routes.any((r) => r.key == rawKey) || routeLabelsConfig.containsKey(rawKey)) {
      return rawKey;
    }
    final cleanTarget = rawKey
        .toLowerCase()
        .replaceAll(RegExp(r'^[Bb]us\s*|^[Bb]'), '')
        .replaceAll('route_', '')
        .replaceAll('route', '')
        .replaceAll('_', '')
        .trim();

    for (var r in _routes) {
      final cleanK = r.key
          .toLowerCase()
          .replaceAll(RegExp(r'^[Bb]us\s*|^[Bb]'), '')
          .replaceAll('route_', '')
          .replaceAll('route', '')
          .replaceAll('_', '')
          .trim();
      if (cleanK == cleanTarget) {
        return r.key;
      }
    }
    for (var k in routeLabelsConfig.keys) {
      final cleanK = k
          .toLowerCase()
          .replaceAll(RegExp(r'^[Bb]us\s*|^[Bb]'), '')
          .replaceAll('route_', '')
          .replaceAll('route', '')
          .replaceAll('_', '')
          .trim();
      if (cleanK == cleanTarget) {
        return k;
      }
    }
    return rawKey;
  }

  List<RouteEntry> _getActiveRegistryRoutes() {
    final List<RouteEntry> result = [];
    final Set<String> seen = {};

    // Strictly return ONLY the routes stored in Firebase Realtime Database (_routes)
    for (var r in _routes) {
      if (r.key.isEmpty && r.name.isEmpty) continue;
      final uniqueKey = (r.key.isNotEmpty ? r.key : r.name).toLowerCase();
      if (!seen.contains(uniqueKey)) {
        seen.add(uniqueKey);
        result.add(r);
      }
    }

    return result;
  }

  List<DropdownMenuItem<String>> _buildRouteDropdownItems(String selectedRouteKey) {
    final List<DropdownMenuItem<String>> items = [];
    final Set<String> addedKeys = {};

    final activeRoutes = _getActiveRegistryRoutes();

    for (var r in activeRoutes) {
      if (r.key.isNotEmpty && !addedKeys.contains(r.key.toLowerCase())) {
        addedKeys.add(r.key.toLowerCase());
        items.add(DropdownMenuItem(
          value: r.key,
          child: Text(r.name.isNotEmpty ? r.name : _getRouteDisplayName(r.key)),
        ));
      }
    }

    // Ensure selectedRouteKey is present if valid and not already added
    if (selectedRouteKey.isNotEmpty && !addedKeys.contains(selectedRouteKey.toLowerCase())) {
      items.add(DropdownMenuItem(
        value: selectedRouteKey,
        child: Text(_getRouteDisplayName(selectedRouteKey)),
      ));
    }

    return items;
  }

  List<LogEntry> _getDefaultLogs() {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final list = _getDefaultDrivers();
    return List.generate(list.length, (i) {
      final d = list[i];
      return LogEntry(
        id: (i + 1).toDouble(),
        bus: d.bus,
        driver: d.driver,
        route: _getRouteDisplayName(d.route),
        date: today,
        arrived: i < 5 ? "0${7 + i}:${(i * 5) < 10 ? '0' : ''}${i * 5}" : null,
        departed: i < 3 ? "1${6 + i}:${(i * 5) < 10 ? '0' : ''}${i * 5}" : null,
        status: i < 5 ? (i == 2 ? 'delayed' : 'arrived') : 'on-route',
      );
    });
  }

  List<AlertEntry> _getDefaultAlerts() {
    return [];
  }

  // ─── FIREBASE LISTENER (STUDENT LETTERS) ─────────────────────────
  void _listenForRequests() {
    if (Firebase.apps.isEmpty) return;
    try {
      _requestsSub = FirebaseDatabase.instance.ref('pickup_requests').onValue.listen((event) {
        final data = event.snapshot.value as Map?;
        final List<Map<String, dynamic>> temp = [];
        if (data != null) {
          data.forEach((key, val) {
            if (val is Map) {
              temp.add({
                'studentId': key,
                'studentName': val['studentName'] ?? "Unknown Student",
                'studentYear': val['studentYear'] ?? "N/A",
                'studentDept': val['studentDept'] ?? "N/A",
                'studentBus': val['studentBus'] ?? val['bus'] ?? "",
                'documentName': val['documentName'] ?? "No Document",
                'documentUrl': val['documentUrl'] ?? "",
                'voiceReasonTamil': val['voiceReasonTamil'] ?? "",
                'status': val['status'] ?? "pending",
                'savedStop': val['savedStop'] ?? "Not Selected",
                'timestamp': val['timestamp'] ?? 0,
              });
            }
          });
          temp.sort((a, b) => b['timestamp'].compareTo(a['timestamp']));
        }
        if (mounted) {
          setState(() {
            _requests = temp;
            _isLoadingRequests = false;
          });
        }
      });
    } catch (e) {
      debugPrint("Error listening to admin requests: $e");
      if (mounted) {
        setState(() {
          _isLoadingRequests = false;
        });
      }
    }
  }

  Widget _buildEnlargedProfileAvatar(String? base64Str, String studentId, String name) {
    Widget buildImageFromB64(String rawB64) {
      String b64 = rawB64;
      if (b64.startsWith('base64:')) {
        b64 = b64.substring(7);
      }
      b64 = b64.replaceAll(RegExp(r'\s+'), '');
      int padding = b64.length % 4;
      if (padding > 0) {
        b64 += '=' * (4 - padding);
      }
      try {
        return ClipOval(
          child: Image.memory(
            base64Decode(b64),
            width: 200,
            height: 200,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _buildFallbackAvatar(name),
          ),
        );
      } catch (e) {
        return _buildFallbackAvatar(name);
      }
    }

    if (base64Str != null && base64Str.isNotEmpty) {
      return buildImageFromB64(base64Str);
    }

    if (studentId.isNotEmpty) {
      return FutureBuilder<DatabaseEvent>(
        future: FirebaseDatabase.instance.ref('students/$studentId').once(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: Colors.white));
          }
          if (snapshot.hasData && snapshot.data!.snapshot.value != null) {
            final data = snapshot.data!.snapshot.value;
            if (data is Map) {
              final b64 = (data['profilePicBase64'] ?? data['photo'] ?? data['studentPhoto']) as String?;
              if (b64 != null && b64.isNotEmpty) {
                return buildImageFromB64(b64);
              }
            }
          }
          return _buildFallbackAvatar(name);
        },
      );
    }

    return _buildFallbackAvatar(name);
  }

  Widget _buildFallbackAvatar(String name) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.person, size: 85, color: Colors.white),
          const SizedBox(height: 4),
          Text(
            name.isNotEmpty ? name[0].toUpperCase() : 'S',
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w900,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  void _showEnlargedStudentProfile(BuildContext context, Map<String, dynamic> student) {
    final name = student['studentName']?.toString() ?? 'Student';
    final rollNo = student['studentId']?.toString() ?? student['rollNo']?.toString() ?? '';
    final dept = student['studentDept']?.toString() ?? student['dept']?.toString() ?? 'N/A';
    final year = student['studentYear']?.toString() ?? student['year']?.toString() ?? 'N/A';
    final bus = student['studentBus']?.toString() ?? student['bus']?.toString() ?? 'N/A';
    final stop = student['savedStop']?.toString() ?? 'Not Selected';

    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white, size: 30),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ),
              const SizedBox(height: 10),
              // WhatsApp style enlarged profile picture
              Hero(
                tag: 'profile_$rollNo',
                child: Container(
                  width: 200,
                  height: 200,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E3A8A),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.6),
                        blurRadius: 25,
                        spreadRadius: 4,
                      ),
                    ],
                    border: Border.all(color: Colors.white, width: 4),
                  ),
                  child: _buildEnlargedProfileAvatar(
                    student['profilePicBase64'] as String?,
                    rollNo,
                    name,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 15,
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF0F172A),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      rollNo.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2563EB),
                      ),
                    ),
                    const Divider(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        Column(
                          children: [
                            const Text("DEPARTMENT", style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.bold, color: Colors.grey)),
                            const SizedBox(height: 2),
                            Text(dept, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFF1E293B))),
                          ],
                        ),
                        Column(
                          children: [
                            const Text("YEAR", style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.bold, color: Colors.grey)),
                            const SizedBox(height: 2),
                            Text(year, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFF1E293B))),
                          ],
                        ),
                        Column(
                          children: [
                            const Text("BUS", style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.bold, color: Colors.grey)),
                            const SizedBox(height: 2),
                            Text("Bus $bus", style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFF16A34A))),
                          ],
                        ),
                      ],
                    ),
                    if (stop.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.location_on, size: 14, color: Color(0xFF2563EB)),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              "Boarding: $stop",
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF475569)),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _extractBusNumber(String raw) {
    if (raw.isEmpty) return "";
    final matches = RegExp(r'\d+').allMatches(raw).map((m) => m.group(0)).toList();
    if (matches.isNotEmpty) {
      return matches.first ?? raw.trim();
    }
    return raw.trim();
  }

  String _getRouteForBus(String busNo) {
    if (busNo.isEmpty) return "";
    final cleanBus = busNo.replaceAll(RegExp(r'[^\d]'), '');
    if (cleanBus.isEmpty) return "";
    
    final driver = _drivers.firstWhere(
      (d) => d.bus.replaceAll(RegExp(r'[^\d]'), '') == cleanBus,
      orElse: () => DriverEntry(id: 0, bus: '', driver: '', route: '', type: ''),
    );
    if (driver.route.isNotEmpty) {
      return _getRouteDisplayName(driver.route);
    }
    
    final routeMatch = _routes.firstWhere(
      (r) => r.key.replaceAll(RegExp(r'[^\d]'), '') == cleanBus || r.name.contains(cleanBus),
      orElse: () => RouteEntry(id: 0, key: '', name: '', stops: [], color: ''),
    );
    if (routeMatch.name.isNotEmpty) {
      return routeMatch.name;
    }
    return "Route $cleanBus";
  }

  void _openApprovalVoiceDialog(Map<String, dynamic> req) {
    final studentName = req['studentName']?.toString() ?? 'Student';
    final studentId = req['studentId']?.toString() ?? '';

    bool isRecording = false;
    int recordDuration = 0;
    Timer? durationTimer;
    String? recordedAudioPath;
    String recordedBase64 = "";

    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDlgState) {
            void startDialogRecording() async {
              try {
                if (await _audioRecorder.hasPermission()) {
                  if (kIsWeb) {
                    await _audioRecorder.start(const RecordConfig(), path: '');
                  } else {
                    final dir = await getApplicationDocumentsDirectory();
                    recordedAudioPath = '${dir.path}/approval_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
                    await _audioRecorder.start(const RecordConfig(), path: recordedAudioPath!);
                  }
                  recordDuration = 0;
                  setDlgState(() {
                    isRecording = true;
                  });
                  durationTimer = Timer.periodic(const Duration(seconds: 1), (t) {
                    if (context.mounted) {
                      setDlgState(() {
                        recordDuration++;
                      });
                    }
                  });
                }
              } catch (e) {
                debugPrint("Error starting voice record: $e");
              }
            }

            void stopDialogRecording() async {
              durationTimer?.cancel();
              try {
                final path = await _audioRecorder.stop();
                if (path != null && path.isNotEmpty) {
                  recordedAudioPath = path;
                  Uint8List bytes;
                  if (kIsWeb) {
                    final res = await http.get(Uri.parse(path));
                    bytes = res.bodyBytes;
                  } else {
                    final file = File(path);
                    bytes = await file.readAsBytes();
                  }
                  recordedBase64 = base64Encode(bytes);
                  debugPrint("Audio file read successfully: ${bytes.length} bytes");
                }
              } catch (e) {
                debugPrint("Error stopping recorder: $e");
              }
              setDlgState(() {
                isRecording = false;
              });
            }

            void toggleRecording() {
              if (isRecording) {
                stopDialogRecording();
              } else {
                startDialogRecording();
              }
            }

            final durationStr = "0:${recordDuration.toString().padLeft(2, '0')}";

            return Dialog(
              backgroundColor: const Color(0xFFF1F5F9),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 10),
                    // Centered Large Blue/Red Mic Button matching Image 2
                    GestureDetector(
                      onTap: toggleRecording,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        width: 84,
                        height: 84,
                        decoration: BoxDecoration(
                          color: isRecording ? const Color(0xFFDC2626) : const Color(0xFF2563EB),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: (isRecording ? const Color(0xFFDC2626) : const Color(0xFF2563EB)).withValues(alpha: 0.4),
                              blurRadius: isRecording ? 22 : 12,
                              spreadRadius: isRecording ? 6 : 2,
                            ),
                          ],
                        ),
                        child: Center(
                          child: Icon(
                            isRecording ? Icons.stop_rounded : Icons.mic,
                            size: 42,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      isRecording
                          ? "🔴 Recording... $durationStr (Tap mic to finish)"
                          : (recordDuration > 0
                              ? "✅ Voice Note Recorded ($durationStr)"
                              : "Tap to speak in English/Tamil (Optional)"),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isRecording ? const Color(0xFFDC2626) : const Color(0xFF64748B),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    if (recordDuration > 0 && !isRecording) ...[
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFCBD5E1)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.graphic_eq_rounded, color: Color(0xFF2563EB), size: 20),
                            const SizedBox(width: 8),
                            Text(
                              "🎙️ Direct Voice Note ($durationStr)",
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 32),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Left: Skip Voice button matching Image 2
                        TextButton(
                          onPressed: () {
                            durationTimer?.cancel();
                            if (isRecording) {
                              _audioRecorder.stop();
                            }
                            Navigator.pop(ctx);
                            _approveLetterWithoutVoice(req);
                          },
                          child: const Text(
                            "Skip Voice",
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF2563EB)),
                          ),
                        ),
                        // Right: Confirm & Approve pill button matching Image 2
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: const Color(0xFF2563EB),
                            elevation: 1,
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(30),
                              side: const BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
                            ),
                          ),
                          onPressed: () async {
                            durationTimer?.cancel();
                            if (isRecording) {
                              try {
                                final path = await _audioRecorder.stop();
                                if (path != null && path.isNotEmpty) {
                                  recordedAudioPath = path;
                                  Uint8List bytes;
                                  if (kIsWeb) {
                                    final res = await http.get(Uri.parse(path));
                                    bytes = res.bodyBytes;
                                  } else {
                                    final file = File(path);
                                    bytes = await file.readAsBytes();
                                  }
                                  recordedBase64 = base64Encode(bytes);
                                }
                              } catch (e) {
                                debugPrint("Stop error: $e");
                              }
                            }
                            if (recordedBase64.isEmpty && recordedAudioPath != null && recordedAudioPath!.isNotEmpty) {
                              try {
                                Uint8List bytes;
                                if (kIsWeb) {
                                  final res = await http.get(Uri.parse(recordedAudioPath!));
                                  bytes = res.bodyBytes;
                                } else {
                                  final file = File(recordedAudioPath!);
                                  bytes = await file.readAsBytes();
                                }
                                recordedBase64 = base64Encode(bytes);
                              } catch (e) {
                                debugPrint("Read file error: $e");
                              }
                            }

                            Navigator.pop(ctx);
                            final voiceLabel = recordDuration > 0
                                ? "🎙️ Direct Admin Voice Note ($durationStr)"
                                : "🎙️ Admin Voice Instruction for $studentName";
                            _approveAndSendVoiceToDriver(
                              req,
                              voiceLabel,
                              recordedBase64,
                              recordDuration > 0 ? recordDuration : 5,
                            );
                          },
                          child: const Text(
                            "Confirm & Approve",
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF2563EB)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _approveLetterWithoutVoice(Map<String, dynamic> req) async {
    final studentId = req['studentId']?.toString() ?? '';
    if (studentId.isEmpty) return;

    try {
      await FirebaseDatabase.instance.ref('pickup_requests/$studentId').update({'status': 'confirmed'});
      _showAppSnackBar("✅ அனுமதி ஏற்கப்பட்டது (குரல் செய்தி இன்றி)");
    } catch (e) {
      _showAppSnackBar("Failed to approve request: $e");
    }
  }

  void _approveAndSendVoiceToDriver(Map<String, dynamic> req, String voiceText, String base64Audio, int durationSecs) async {
    final studentId = req['studentId']?.toString() ?? '';
    if (studentId.isEmpty) return;

    try {
      await FirebaseDatabase.instance.ref('pickup_requests/$studentId').update({
        'status': 'confirmed',
        'adminVoiceText': voiceText,
        'adminVoiceAudio': base64Audio,
        'adminVoiceDuration': durationSecs,
      });

      _showAppSnackBar("✅ அனுமதி ஏற்கப்பட்டது. நேரடி குரல் செய்தி கடிதத்துடன் இணைக்கப்பட்டது!");
    } catch (e) {
      _showAppSnackBar("Failed to approve request: $e");
    }
  }

  void _updateRequestStatus(String studentId, String status) async {
    try {
      await FirebaseDatabase.instance.ref('pickup_requests/$studentId/status').set(status);
      _showAppSnackBar("Request status set to $status");
    } catch (e) {
      _showAppSnackBar("Failed to update status: $e");
    }
  }

  void _deleteRequest(String studentId) async {
    try {
      await FirebaseDatabase.instance.ref('pickup_requests/$studentId').remove();
      _showAppSnackBar("Pickup request deleted");
    } catch (e) {
      _showAppSnackBar("Failed to delete request: $e");
    }
  }

  // ─── FIREBASE INTERCOM MESSAGES ──────────────────────────────────
  void _listenForAdminIntercomMessages() {
    if (Firebase.apps.isEmpty) return;
    try {
      _adminIntercomSub = FirebaseDatabase.instance.ref('voice_messages').onValue.listen((event) {
        final data = event.snapshot.value as Map?;
        final Map<String, List<Map<String, dynamic>>> temp = {};
        if (data != null) {
          data.forEach((busId, msgs) {
            if (msgs is Map) {
              final List<Map<String, dynamic>> busMsgs = [];
              msgs.forEach((k, v) {
                if (v is Map) {
                  int parseTs(dynamic val) {
                    if (val == null) return 0;
                    if (val is int) return val;
                    if (val is num) return val.toInt();
                    if (val is String) {
                      final p = int.tryParse(val);
                      if (p != null) return p;
                      final dt = DateTime.tryParse(val);
                      if (dt != null) return dt.millisecondsSinceEpoch;
                    }
                    return 0;
                  }

                  busMsgs.add({
                    'id': k.toString(),
                    'sender': v['sender']?.toString() ?? 'unknown',
                    'senderName': v['senderName']?.toString() ?? '',
                    'timestamp': parseTs(v['timestamp']),
                    'msg': v['msg']?.toString() ?? '',
                    'isVoice': v['isVoice'] == true,
                    'voiceDuration': (v['voiceDuration'] is num) ? (v['voiceDuration'] as num).toInt() : 0,
                    'mongoId': v['mongoId']?.toString() ?? '',
                    'isRead': v['isRead'] == true,
                  });
                }
              });
              busMsgs.sort((a, b) => (a['timestamp'] as int).compareTo(b['timestamp'] as int));
              temp[busId.toString()] = busMsgs;
            }
          });
        }
        if (mounted) {
          setState(() {
            _adminIntercomMessages = temp;
            // Persistent DB isRead status + lastSeen: compute unread messages per bus
            final Map<String, int> newUnread = {};
            temp.forEach((busKey, msgs) {
              final busNum = busKey.replaceFirst('driver_', '');
              if (_selectedIntercomBus == busNum) {
                // Admin is currently viewing this chat -> mark as read immediately
                _markMessagesAsRead(busNum);
              } else {
                final lastSeen = _lastSeenTimestamp[busNum] ?? 0;
                final unread = msgs.where((m) {
                  if (m['sender'] == 'admin') return false;
                  if (m['isRead'] == true) return false;
                  final ts = m['timestamp'] as int? ?? 0;
                  if (lastSeen > 0 && ts <= lastSeen) return false;
                  return true;
                }).length;
                if (unread > 0) newUnread[busNum] = unread;
              }
            });
            _unreadPerBus = newUnread;
          });
          // Auto-scroll to bottom (latest message) after frame renders
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_chatScrollController.hasClients) {
              _chatScrollController.animateTo(
                _chatScrollController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
              );
            }
          });
        }
      });
    } catch (e) {
      debugPrint("Error loading admin intercom: $e");
    }
  }

  void _markMessagesAsRead(String busNum) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastSeenTimestamp[busNum] = now;
    _unreadPerBus.remove(busNum);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('intercom_last_seen_$busNum', now);
    } catch (_) {}

    if (Firebase.apps.isNotEmpty) {
      try {
        final msgs = _adminIntercomMessages['driver_$busNum'] ?? [];
        for (final m in msgs) {
          if (m['isRead'] != true) {
            m['isRead'] = true;
            final msgId = m['id'];
            if (msgId != null && msgId.toString().isNotEmpty) {
              FirebaseDatabase.instance
                  .ref('voice_messages/driver_$busNum/$msgId/isRead')
                  .set(true)
                  .catchError((_) {});
            }
          }
        }
      } catch (e) {
        debugPrint("Error marking messages as read: $e");
      }
    }
  }

  void _sendAdminTextMessage(String busId, String text) async {
    if (Firebase.apps.isEmpty) return;
    try {
      final msgId = DateTime.now().millisecondsSinceEpoch.toString();
      await FirebaseDatabase.instance.ref('voice_messages/driver_$busId/$msgId').set({
        'sender': 'admin',
        'senderName': 'College Admin',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'msg': text,
      });
      _adminChatInputCtrl.clear();
    } catch (e) {
      _showAppSnackBar("Error sending intercom message: $e");
    }
  }

  void _startRecordingVoice() async {
    if (await _audioRecorder.hasPermission()) {
      if (kIsWeb) {
        await _audioRecorder.start(const RecordConfig(), path: '');
      } else {
        final dir = await getApplicationDocumentsDirectory();
        _recordPath = '${dir.path}/voice_message_admin.m4a';
        await _audioRecorder.start(const RecordConfig(), path: _recordPath!);
      }
      setState(() {
        _isRecordingVoice = true;
        _recordingDurationSecs = 0;
        _recordingWaveforms = [];
      });
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (mounted) {
          setState(() {
            _recordingDurationSecs++;
            _recordingWaveforms.add(5.0 + (DateTime.now().millisecondsSinceEpoch % 30));
          });
        }
      });
    }
  }

  void _stopAndSendRecordingVoice() async {
    _recordingTimer?.cancel();
    if (!_isRecordingVoice) return;
    
    final path = await _audioRecorder.stop();
    final duration = _recordingDurationSecs == 0 ? 3 : _recordingDurationSecs;
    setState(() {
      _isRecordingVoice = false;
    });

    if (path != null && Firebase.apps.isNotEmpty && _selectedIntercomBus != null) {
      try {
        Uint8List bytes;
        if (kIsWeb) {
          final res = await http.get(Uri.parse(path));
          bytes = res.bodyBytes;
        } else {
          bytes = await File(path).readAsBytes();
        }
        final base64Audio = base64Encode(bytes);
        
        final String apiUrl = kIsWeb
      ? 'https://panimalr-bus.onrender.com/api/voice'
      : 'https://panimalr-bus.onrender.com/api/voice';
        final response = await http.post(
          Uri.parse(apiUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'sender': 'admin',
            'receiver': 'driver_$_selectedIntercomBus',
            'audioBase64': base64Audio,
            'duration': duration,
          }),
        );
        
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final mongoId = data['id'];
          
          final msgId = DateTime.now().millisecondsSinceEpoch.toString();
          await FirebaseDatabase.instance.ref('voice_messages/driver_$_selectedIntercomBus/$msgId').set({
            'sender': 'admin',
            'senderName': 'College Admin',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'msg': '[Voice Message - 0:${duration.toString().padLeft(2, '0')}] "$mongoId"',
            'isVoice': true,
            'voiceDuration': duration,
            'mongoId': mongoId,
          });
        }
      } catch (e) {
        debugPrint("Error sending voice message: $e");
      }
    }
  }

  void _cancelRecordingVoice() async {
    _recordingTimer?.cancel();
    await _audioRecorder.stop();
    setState(() {
      _isRecordingVoice = false;
      _recordingDurationSecs = 0;
    });
    _showAppSnackBar("Recording cancelled.");
  }

  void _playVoiceMessage(String msgId, String mongoId, int durationSecs) async {
    if (_playingMsgId == msgId) {
      _playbackTimer?.cancel();
      await _audioPlayer.stop();
      setState(() {
        _playingMsgId = null;
      });
      return;
    }
    _playbackTimer?.cancel();
    await _audioPlayer.stop();

    setState(() {
      _playingMsgId = msgId;
      _playbackProgress = 0.0;
    });

    if (mongoId.isNotEmpty) {
      try {
        final String apiUrl = kIsWeb ? 'https://panimalr-bus.onrender.com/api/voice/$mongoId' : 'https://panimalr-bus.onrender.com/api/voice/$mongoId';
        final response = await http.get(Uri.parse(apiUrl));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final audioBytes = base64Decode(data['audioBase64']);
          await _audioPlayer.play(BytesSource(audioBytes));
        }
      } catch (e) {
        debugPrint("Error playing audio: $e");
      }
    }
    
    final int totalSteps = durationSecs * 10;
    int currentStep = 0;
    _playbackTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      currentStep++;
      if (mounted) {
        setState(() {
          _playbackProgress = currentStep / totalSteps;
        });
      }
      if (currentStep >= totalSteps) {
        timer.cancel();
        if (mounted) {
          setState(() {
            _playingMsgId = null;
            _playbackProgress = 0.0;
          });
        }
      }
    });
  }

  // ─── FIREBASE LIVE LOCATIONS ──────────────────────────────────────
  void _listenForLiveLocations() {
    if (Firebase.apps.isEmpty) return;
    try {
      _liveLocationsSub = FirebaseDatabase.instance.ref('liveLocations').onValue.listen((event) {
        final data = event.snapshot.value as Map?;
        final Map<String, Map<String, dynamic>> temp = {};
        if (data != null) {
          data.forEach((k, v) {
            if (v is Map) {
              final mapV = Map<String, dynamic>.from(v);
              final status = mapV['status'] as String? ?? 'offline';
              final rawUpdatedAt = mapV['updatedAt'] as String?;
              bool isStale = false;
              if (rawUpdatedAt != null) {
                try {
                  final dt = DateTime.parse(rawUpdatedAt).toLocal();
                  if (DateTime.now().difference(dt).inMinutes > 5) {
                    isStale = true;
                  }
                } catch (_) {}
              }
              if (isStale && status != 'completed') {
                mapV['status'] = 'offline';
              }
              temp[k.toString()] = mapV;
            }
          });
        }
        if (mounted) {
          setState(() {
            _liveBuses = temp;
          });
        }
      });
    } catch (e) {
      debugPrint("Error listening to live locations: $e");
    }
  }

  void _listenForArrivalLogs() {
    _arrivalLogsSub?.cancel();
    if (Firebase.apps.isEmpty) return;
    try {
      final today = DateTime.now().toIso8601String().substring(0, 10);
      _arrivalLogsSub = FirebaseDatabase.instance
          .ref('arrival_logs/$today')
          .onValue
          .listen((event) {
            final data = event.snapshot.value as Map?;
            final List<LogEntry> temp = [];
            if (data != null) {
              data.forEach((key, val) {
                if (val is Map) {
                  temp.add(
                    LogEntry(
                      id: (val['timestamp'] as num?)?.toDouble() ?? DateTime.now().millisecondsSinceEpoch.toDouble(),
                      bus: val['bus'] ?? key,
                      driver: val['driver'] ?? 'Unknown',
                      route: val['route'] ?? 'Unknown',
                      date: val['date'] ?? today,
                      arrived: val['arrived'],
                      departed: val['departed'],
                      status: val['status'] ?? 'arrived',
                    ),
                  );
                }
              });
            }
            if (mounted) {
              setState(() {
                _arrivalLogs = temp;
              });
            }
          });
    } catch (e) {
      debugPrint("Error listening to arrival logs: $e");
    }
  }

  void _listenForBreakdowns() {
    _breakdownListenerSub?.cancel();
    if (Firebase.apps.isEmpty) return;
    try {
      _breakdownListenerSub = FirebaseDatabase.instance.ref('breakdownAlerts').onValue.listen((event) {
        final data = event.snapshot.value as Map?;
        final List<Map<String, dynamic>> loaded = [];
        if (data != null) {
          data.forEach((k, v) {
            if (v is Map) {
              loaded.add({
                'id': k.toString(),
                'busId': v['busId']?.toString() ?? '',
                'message': v['message']?.toString() ?? '',
                'timestamp': v['timestamp'] ?? 0,
              });
            }
          });
        }
        loaded.sort((a, b) => b['timestamp'].compareTo(a['timestamp']));
        if (mounted) {
          setState(() {
            final oldLen = _adminBreakdownsList.length;
            _adminBreakdownsList = loaded;
            if (loaded.length > oldLen && oldLen != 0) {
              _adminUnreadCount += (loaded.length - oldLen);
            } else if (oldLen == 0) {
              _adminUnreadCount = loaded.length;
            }
          });
        }
      });
    } catch (e) {
      debugPrint("Error listening to breakdowns: $e");
    }
  }

  void _showBreakdownNotifications() {
    setState(() {
      _adminUnreadCount = 0;
    });
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Container(
          height: MediaQuery.of(ctx).size.height * 0.7,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(t('Driver Breakdown Alerts'), style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1E3A8A))),
                  IconButton(
                    icon: Icon(Icons.close, color: Color(0xFF64748B)),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              SizedBox(height: 12),
              Expanded(
                child: _adminBreakdownsList.isEmpty
                    ? Center(child: Text(t('No breakdowns reported.'), style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)))
                    : ListView.separated(
                        itemCount: _adminBreakdownsList.length,
                        separatorBuilder: (_, _) => Divider(height: 1),
                        itemBuilder: (context, index) {
                          final b = _adminBreakdownsList[index];
                          final isReady = b['message'].toString().toLowerCase().contains("started the journey");
                          
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(vertical: 8),
                            leading: CircleAvatar(
                              backgroundColor: isReady ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2), 
                              child: Icon(
                                isReady ? Icons.check_circle : Icons.warning_amber_rounded, 
                                color: isReady ? const Color(0xFF16A34A) : const Color(0xFFDC2626)
                              )
                            ),
                            title: Text(
                              "Bus ${b['busId']} Alert", 
                              style: TextStyle(
                                fontWeight: FontWeight.bold, 
                                color: isReady ? const Color(0xFF14532D) : const Color(0xFF991B1B)
                              )
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  b['message'], 
                                  style: TextStyle(
                                    fontSize: 13, 
                                    fontWeight: FontWeight.w600,
                                    color: isReady ? const Color(0xFF16A34A) : const Color(0xFFDC2626)
                                  )
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  b['timestamp'] != 0 
                                      ? DateFormat('hh:mm a').format(DateTime.fromMillisecondsSinceEpoch(b['timestamp']))
                                      : 'Unknown time',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[600],
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                            isThreeLine: true,
                            trailing: IconButton(
                              icon: Icon(Icons.delete_outline, color: Colors.grey),
                              onPressed: () {
                                if (Firebase.apps.isNotEmpty) {
                                  FirebaseDatabase.instance.ref('breakdownAlerts/${b['id']}').remove();
                                }
                                setModalState(() {
                                  _adminBreakdownsList.removeAt(index);
                                });
                              },
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── DRIVER LOCATIONS SETTINGS & SUGGESTIONS ──────────────────────
  void _listenForAdminSettings() {
    if (Firebase.apps.isEmpty) return;
    try {
      _adminSettingsSub = FirebaseDatabase.instance.ref('adminSettings/allowDriversToAddStops').onValue.listen((event) {
        final val = event.snapshot.value;
        if (mounted) {
          setState(() {
            _allowDriversToAddStops = val == true;
          });
        }
      });
    } catch (e) {
      debugPrint("Error listening to admin settings: $e");
    }
  }

  void _listenForNewStops() {
    if (Firebase.apps.isEmpty) return;
    try {
      _newStopsSub = FirebaseDatabase.instance.ref('new_stops').onValue.listen((event) {
        final data = event.snapshot.value as Map?;
        final List<Map<String, dynamic>> temp = [];
        if (data != null) {
          data.forEach((k, v) {
            if (v is Map) {
              final m = Map<String, dynamic>.from(v);
              m['_key'] = k.toString();
              temp.add(m);
            }
          });
          // Sort chronologically (earliest to latest = travel sequence from departure to terminus)
          temp.sort((a, b) => (a['timestamp'] as int? ?? 0).compareTo(b['timestamp'] as int? ?? 0));
          if (mounted) {
            setState(() {
              _newStops = temp;
            });
            _autoSyncCapturedStopsToRouteRegistry(temp);
          }
        } else {
          if (mounted) {
            setState(() {
              _newStops = [];
            });
          }
        }
      });
    } catch (e) {
      debugPrint("Error listening to new stops: $e");
    }

    try {
      _specialBusesSub = FirebaseDatabase.instance.ref('special_buses').onValue.listen((event) {
        final data = event.snapshot.value as Map?;
        final List<Map<String, dynamic>> temp = [];
        if (data != null) {
          data.forEach((k, v) {
            if (v is Map) {
              temp.add({...Map<String, dynamic>.from(v), 'id': k});
            }
          });
          if (mounted) {
            setState(() {
              _specialBuses = temp;
            });
          }
        } else {
          if (mounted) {
            setState(() {
              _specialBuses = [];
            });
          }
        }
      });
    } catch (e) {
      debugPrint("Error listening to special buses: $e");
    }
  }


  void _showAppSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontWeight: FontWeight.bold)),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: const Color(0xFF2563EB),
      ),
    );
  }

  // ─── ADMIN DIALOGS & FORMS ───────────────────────────────────────
  void _openDriverAddBottomSheet() {
    final busCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    String selRoute = _resolveSelectedRouteKey('');
    String selType = 'combined';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (c, setSheetState) => DraggableScrollableSheet(
          initialChildSize: 0.70,
          maxChildSize: 0.90,
          minChildSize: 0.45,
          builder: (_, scrollController) => Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, top: 20, left: 20, right: 20),
            child: SingleChildScrollView(
              controller: scrollController,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(t('Add Driver & Bus Entry'), style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1E3A8A))),
                      IconButton(
                        icon: Icon(Icons.close, color: Color(0xFF64748B)),
                        onPressed: () => Navigator.pop(context),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                SizedBox(height: 16),
                TextField(controller: busCtrl, decoration: const InputDecoration(labelText: "Bus Number (e.g. B110)")),
                SizedBox(height: 8),
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: "Driver Name")),
                SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selRoute,
                  decoration: const InputDecoration(labelText: "Assign Route"),
                  items: _buildRouteDropdownItems(selRoute),
                  onChanged: (val) => setSheetState(() => selRoute = val!),
                ),
                SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selType,
                  decoration: const InputDecoration(labelText: "Bus Gender Category"),
                  items: [
                    DropdownMenuItem(value: 'boys', child: Text(t('Boys Bus'))),
                    DropdownMenuItem(value: 'girls', child: Text(t('Girls Bus'))),
                    DropdownMenuItem(value: 'combined', child: Text(t('Combined'))),
                  ],
                  onChanged: (val) => setSheetState(() => selType = val!),
                ),
                SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2563EB), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30))),
                  onPressed: () {
                    final b = busCtrl.text.trim().toUpperCase();
                    final n = nameCtrl.text.trim();
                    if (b.isEmpty || n.isEmpty) {
                      _showAppSnackBar("Please fill bus number and driver name.");
                      return;
                    }
                    final newDriver = DriverEntry(
                      id: DateTime.now().millisecondsSinceEpoch.toDouble(),
                      bus: b,
                      driver: n,
                      route: selRoute,
                      type: selType,
                    );
                    setState(() {
                      _drivers.add(newDriver);
                      _saveDrivers();
                    });
                    if (Firebase.apps.isNotEmpty) {
                      try {
                        FirebaseDatabase.instance.ref('drivers/$b').set(newDriver.toJson());
                      } catch (e) {
                        debugPrint("Error writing new driver to Firebase: $e");
                      }
                    }
                    Navigator.pop(ctx);
                    _showAppSnackBar("Driver registry created & synced to Firebase.");
                  },
                  child: Text(t('Save Registry Entry'), style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  void _openDriverEditBottomSheet(DriverEntry entry) {
    final busCtrl = TextEditingController(text: entry.bus);
    final nameCtrl = TextEditingController(text: entry.driver);
    String selRoute = _resolveSelectedRouteKey(entry.route);
    String selType = entry.type;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (c, setSheetState) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, top: 20, left: 20, right: 20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(t('Edit Driver & Bus Entry'), style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1E3A8A))),
                SizedBox(height: 16),
                TextField(controller: busCtrl, decoration: const InputDecoration(labelText: "Bus Number")),
                SizedBox(height: 8),
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: "Driver Name")),
                SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selRoute,
                  decoration: const InputDecoration(labelText: "Assign Route"),
                  items: _buildRouteDropdownItems(selRoute),
                  onChanged: (val) => setSheetState(() => selRoute = val!),
                ),
                SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selType,
                  decoration: const InputDecoration(labelText: "Bus Gender Category"),
                  items: [
                    DropdownMenuItem(value: 'boys', child: Text(t('Boys Bus'))),
                    DropdownMenuItem(value: 'girls', child: Text(t('Girls Bus'))),
                    DropdownMenuItem(value: 'combined', child: Text(t('Combined'))),
                  ],
                  onChanged: (val) => setSheetState(() => selType = val!),
                ),
                SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2563EB), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30))),
                  onPressed: () {
                    final b = busCtrl.text.trim().toUpperCase();
                    final n = nameCtrl.text.trim();
                    if (b.isEmpty || n.isEmpty) {
                      _showAppSnackBar("Please fill bus number and driver name.");
                      return;
                    }
                    final updatedDriver = DriverEntry(
                      id: entry.id,
                      bus: b,
                      driver: n,
                      route: selRoute,
                      type: selType,
                    );
                    setState(() {
                      final idx = _drivers.indexWhere((item) => item.id == entry.id);
                      if (idx != -1) {
                        _drivers[idx] = updatedDriver;
                      }
                      _saveDrivers();
                    });
                    if (Firebase.apps.isNotEmpty) {
                      try {
                        if (entry.bus != b) {
                          FirebaseDatabase.instance.ref('drivers/${entry.bus}').remove();
                        }
                        FirebaseDatabase.instance.ref('drivers/$b').set(updatedDriver.toJson());
                      } catch (e) {
                        debugPrint("Error updating driver in Firebase: $e");
                      }
                    }
                    Navigator.pop(ctx);
                    _showAppSnackBar("Driver registry updated.");
                  },
                  child: Text(t('Save Registry Entry'), style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openRouteAddBottomSheet() {
    final keyCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final stopsCtrl = TextEditingController();
    List<String> currentStops = [];
    final colorCtrl = TextEditingController(text: "#2563EB");
    String errorMsg = "";

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => DraggableScrollableSheet(
          initialChildSize: 0.75,
          maxChildSize: 0.95,
          minChildSize: 0.5,
          builder: (_, scrollController) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, top: 20, left: 20, right: 20),
          child: SingleChildScrollView(
            controller: scrollController,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(t('Add College Transit Route'), style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1E3A8A))),
                    IconButton(
                      icon: Icon(Icons.close, color: Color(0xFF64748B)),
                      onPressed: () => Navigator.pop(context),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              SizedBox(height: 16),
              TextField(controller: keyCtrl, decoration: const InputDecoration(labelText: "Route Key (e.g. route_15)")),
              SizedBox(height: 8),
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: "Route Display Name")),
              SizedBox(height: 8),
              TextField(
                controller: stopsCtrl, 
                decoration: const InputDecoration(labelText: "Stops (comma separated)", hintText: "Porur, Poonamallee, College"),
                onChanged: (val) {
                  setSheetState(() {
                    currentStops = _parseRouteStops(val);
                  });
                },
              ),
              const SizedBox(height: 12),
              const Text(
                "Drag stops to reorder sequence:",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF1E3A8A)),
              ),
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: currentStops.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text("No stops entered. Type comma-separated stops above.", style: TextStyle(fontSize: 11, color: Colors.grey)),
                      )
                    : ReorderableListView.builder(
                        shrinkWrap: true,
                        itemCount: currentStops.length,
                        onReorder: (oldIndex, newIndex) {
                          setSheetState(() {
                            if (newIndex > oldIndex) newIndex -= 1;
                            final item = currentStops.removeAt(oldIndex);
                            currentStops.insert(newIndex, item);
                            stopsCtrl.text = currentStops.join(', ');
                          });
                        },
                        itemBuilder: (ctx, index) {
                          final stop = currentStops[index];
                          final cleanName = _cleanStopName(stop);
                          return Container(
                            key: ValueKey("add_stop_${index}_$stop"),
                            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: const Color(0xFFCBD5E1)),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(6)),
                                  child: Text("${index + 1}", style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF2563EB))),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    cleanName,
                                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Color(0xFFEF4444)),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  tooltip: "Delete Stop",
                                  onPressed: () {
                                    setSheetState(() {
                                      currentStops.removeAt(index);
                                      stopsCtrl.text = currentStops.join(', ');
                                    });
                                  },
                                ),
                                const SizedBox(width: 8),
                                const Icon(Icons.drag_indicator_rounded, size: 20, color: Color(0xFF94A3B8)),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              SizedBox(height: 8),
              TextField(controller: colorCtrl, decoration: const InputDecoration(labelText: "Hex Color", hintText: "#2563EB")),
              SizedBox(height: 20),
              if (errorMsg.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Text(errorMsg, style: const TextStyle(color: Colors.red, fontSize: 13, fontWeight: FontWeight.bold)),
                ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2563EB), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30))),
                onPressed: () {
                  final k = keyCtrl.text.trim();
                  final n = nameCtrl.text.trim();
                  final s = _parseRouteStops(stopsCtrl.text);
                  final c = colorCtrl.text.trim();
                  if (k.isEmpty || n.isEmpty) {
                    setSheetState(() {
                      errorMsg = "Please fill route key and name.";
                    });
                    return;
                  }
                  final newEntry = RouteEntry(
                    id: DateTime.now().millisecondsSinceEpoch.toDouble(),
                    key: k,
                    name: n,
                    stops: s,
                    color: c.isNotEmpty ? c : "#2563EB",
                  );
                  setState(() {
                    _routes.add(newEntry);
                    _saveRoutes();
                  });
                  if (Firebase.apps.isNotEmpty) {
                    try {
                      final rJson = newEntry.toJson();
                      rJson['stops'] = healRouteStops(s);
                      rJson['deleted'] = false;
                      rJson['status'] = 'active';
                      FirebaseDatabase.instance.ref('routes/$k').set(rJson);
                    } catch (e) {
                      debugPrint("Direct route create error: $e");
                    }
                  }
                  Navigator.pop(context);
                  _showAppSnackBar("Route added & saved to Firebase.");
                },
                child: Text(t('Create Route'), style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              SizedBox(height: 20),
            ],
          ),
        ),
      ),
        ),
      ),
    );
  }

  void _openRouteEditBottomSheet(RouteEntry entry) {
    final keyCtrl = TextEditingController(text: entry.key);
    final nameCtrl = TextEditingController(text: entry.name);
    List<String> currentStops = healRouteStops(entry.stops);
    final stopsCtrl = TextEditingController(text: currentStops.join(', '));
    final colorCtrl = TextEditingController(text: entry.color);
    String errorMsg = "";

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, top: 20, left: 20, right: 20),
          child: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t('Edit Transit Route'), style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1E3A8A))),
              SizedBox(height: 16),
              TextField(controller: keyCtrl, decoration: const InputDecoration(labelText: "Route Key")),
              SizedBox(height: 8),
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: "Route Display Name")),
              SizedBox(height: 8),
              TextField(
                controller: stopsCtrl, 
                decoration: const InputDecoration(labelText: "Stops (comma separated)"),
                onChanged: (val) {
                  setSheetState(() {
                    currentStops = _parseRouteStops(val);
                  });
                },
              ),
              const SizedBox(height: 12),
              const Text(
                "Drag stops to reorder sequence:",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF1E3A8A)),
              ),
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(maxHeight: 200),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: currentStops.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text("No stops entered. Type comma-separated stops above.", style: TextStyle(fontSize: 11, color: Colors.grey)),
                      )
                    : ReorderableListView.builder(
                        shrinkWrap: true,
                        itemCount: currentStops.length,
                        onReorder: (oldIndex, newIndex) {
                          setSheetState(() {
                            if (newIndex > oldIndex) newIndex -= 1;
                            final item = currentStops.removeAt(oldIndex);
                            currentStops.insert(newIndex, item);
                            stopsCtrl.text = currentStops.join(', ');
                          });
                        },
                        itemBuilder: (ctx, index) {
                          final stop = currentStops[index];
                          final cleanName = _cleanStopName(stop);

                          void confirmDeleteStop() {
                            showDialog(
                              context: context,
                              builder: (dialogCtx) => AlertDialog(
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                title: Text("Delete Stop '$cleanName'?", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF1E3A8A))),
                                content: const Text(
                                  "This stop will be instantly deleted from the database and removed across all student and driver portals.",
                                  style: TextStyle(fontSize: 13, color: Color(0xFF475569)),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(dialogCtx),
                                    child: const Text("Cancel", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
                                  ),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFFDC2626),
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                    onPressed: () async {
                                      Navigator.pop(dialogCtx);
                                      setSheetState(() {
                                        currentStops.removeAt(index);
                                        stopsCtrl.text = currentStops.join(', ');
                                      });
                                      await _instantDeleteStopFromDatabase(entry.key, currentStops);
                                    },
                                    child: const Text("Delete Stop", style: TextStyle(fontWeight: FontWeight.bold)),
                                  ),
                                ],
                              ),
                            );
                          }

                          return InkWell(
                            key: ValueKey("stop_${index}_$stop"),
                            onTap: confirmDeleteStop,
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: const Color(0xFFCBD5E1)),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(6)),
                                    child: Text("${index + 1}", style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF2563EB))),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      cleanName,
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Color(0xFFEF4444)),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    tooltip: "Delete Stop",
                                    onPressed: confirmDeleteStop,
                                  ),
                                  const SizedBox(width: 8),
                                  const Icon(Icons.drag_indicator_rounded, size: 20, color: Color(0xFF94A3B8)),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              SizedBox(height: 8),
              TextField(controller: colorCtrl, decoration: const InputDecoration(labelText: "Hex Color")),
              SizedBox(height: 20),
              if (errorMsg.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Text(errorMsg, style: const TextStyle(color: Colors.red, fontSize: 13, fontWeight: FontWeight.bold)),
                ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2563EB), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30))),
                onPressed: () {
                  final k = keyCtrl.text.trim();
                  final n = nameCtrl.text.trim();
                  final s = _parseRouteStops(stopsCtrl.text);
                  final c = colorCtrl.text.trim();
                  if (k.isEmpty || n.isEmpty) {
                    setSheetState(() {
                      errorMsg = "Please fill route key and name.";
                    });
                    return;
                  }
                  final updatedEntry = RouteEntry(
                    id: entry.id != 0 ? entry.id : DateTime.now().millisecondsSinceEpoch.toDouble(),
                    key: k,
                    name: n,
                    stops: s,
                    color: c.isNotEmpty ? c : "#2563EB",
                  );

                  setState(() {
                    final idx = _routes.indexWhere((item) => 
                      item.id == entry.id || 
                      item.key.toLowerCase() == entry.key.toLowerCase() || 
                      item.key.toLowerCase() == k.toLowerCase() ||
                      item.name.toLowerCase() == entry.name.toLowerCase()
                    );
                    if (idx != -1) {
                      _routes[idx] = updatedEntry;
                    } else {
                      _routes.add(updatedEntry);
                    }

                    // Also update any matching driver in _drivers
                    final cleanK = k.replaceAll(RegExp(r'[^0-9a-zA-Z]'), '').toLowerCase();
                    final cleanEntryKey = entry.key.replaceAll(RegExp(r'[^0-9a-zA-Z]'), '').toLowerCase();
                    for (int i = 0; i < _drivers.length; i++) {
                      final cleanBus = _drivers[i].bus.replaceAll(RegExp(r'[^0-9a-zA-Z]'), '').toLowerCase();
                      final cleanRoute = _drivers[i].route.replaceAll(RegExp(r'[^0-9a-zA-Z]'), '').toLowerCase();
                      if (cleanRoute == cleanK || cleanRoute == cleanEntryKey || cleanBus == cleanK || cleanK.contains(cleanBus) || _drivers[i].route == entry.key || _drivers[i].route == entry.name) {
                        _drivers[i] = DriverEntry(
                          id: _drivers[i].id,
                          bus: _drivers[i].bus,
                          driver: _drivers[i].driver,
                          route: n,
                          type: _drivers[i].type,
                        );
                      }
                    }
                  });

                  // Direct atomic write to Firebase for instant persistence
                  if (Firebase.apps.isNotEmpty) {
                    try {
                      final rJson = updatedEntry.toJson();
                      rJson['stops'] = healRouteStops(s);
                      rJson['deleted'] = false;
                      rJson['status'] = 'active';
                      FirebaseDatabase.instance.ref('routes/$k').set(rJson);
                    } catch (e) {
                      debugPrint("Direct route write error: $e");
                    }
                  }

                  _saveRoutes();
                  _saveDrivers();

                  Navigator.pop(context);
                  _showAppSnackBar("Route updated & synced to Firebase.");
                },
                child: Text(t('Save Route Settings'), style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              SizedBox(height: 20),
            ],
          ),
        ),
      ),
      ),
    );
  }

  void _openAlertAddBottomSheet() {
    String selectedType = "delay";
    final busCtrl = TextEditingController(text: "B101");
    final msgCtrl = TextEditingController();
    final titleCtrl = TextEditingController();

    // Notification type config
    final types = [
      {'value': 'delay',        'label': '🚌  Delay Alert',       'hint': 'e.g. Bus B101 delayed 20 min due to traffic'},
      {'value': 'route_change', 'label': '🔀  Route Change',      'hint': 'e.g. Route 15 diverted via Ambattur today'},
      {'value': 'emergency',    'label': '🚨  Emergency Alert',   'hint': 'e.g. Bus breakdown, alternate arranged'},
      {'value': 'arrival',      'label': '🛎️  Arrival Notice',    'hint': 'e.g. Bus B202 arriving in 5 minutes'},
      {'value': 'breakdown',    'label': '🔧  Breakdown Notice',  'hint': 'e.g. Bus B303 broke down near Koyambedu'},
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (c, setSheetState) {
          final currentType = types.firstWhere((t) => t['value'] == selectedType);
          return Padding(
            padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
                top: 20, left: 20, right: 20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Drag handle
                  Center(
                    child: Container(
                      width: 40, height: 4,
                      decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  SizedBox(height: 16),
                  Text(t('Send Notification to Students'),
                      style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1E3A8A))),
                  Text(t('Broadcast instant alerts to all student portals via Firebase'),
                      style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                  SizedBox(height: 20),

                  // Type selector grid
                  Text(t('NOTIFICATION TYPE'),
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800,
                          color: Color(0xFF64748B), letterSpacing: 0.5)),
                  SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: types.map((t) {
                      final isSelected = selectedType == t['value'];
                      return GestureDetector(
                        onTap: () => setSheetState(() {
                          selectedType = t['value']!;
                          titleCtrl.text = _defaultNotifTitle(t['value']!);
                        }),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: isSelected ? const Color(0xFF2563EB) : const Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isSelected ? const Color(0xFF2563EB) : const Color(0xFFE2E8F0),
                            ),
                          ),
                          child: Text(
                            t['label']!,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: isSelected ? Colors.white : const Color(0xFF0F172A),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  SizedBox(height: 16),

                  // Title field
                  Text(t('TITLE'),
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800,
                          color: Color(0xFF64748B), letterSpacing: 0.5)),
                  SizedBox(height: 6),
                  TextField(
                    controller: titleCtrl,
                    decoration: InputDecoration(
                      hintText: _defaultNotifTitle(selectedType),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                  SizedBox(height: 12),

                  // Message field
                  Text(t('MESSAGE'),
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800,
                          color: Color(0xFF64748B), letterSpacing: 0.5)),
                  SizedBox(height: 6),
                  TextField(
                    controller: msgCtrl,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: currentType['hint'],
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                  SizedBox(height: 12),

                  // Bus field
                  TextField(
                    controller: busCtrl,
                    decoration: InputDecoration(
                      labelText: "Affected Bus (or 'all')",
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                  SizedBox(height: 20),

                  ElevatedButton.icon(
                    icon: Icon(Icons.send_rounded, size: 16),
                    label: Text(t('Send to All Students'),
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () {
                      final t = selectedType;
                      final b = busCtrl.text.trim().toUpperCase();
                      final m = msgCtrl.text.trim();
                      final title = titleCtrl.text.trim().isNotEmpty
                          ? titleCtrl.text.trim()
                          : _defaultNotifTitle(t);
                      if (m.isEmpty) {
                        _showAppSnackBar("Please enter notification message.");
                        return;
                      }

                      final timeNow =
                          "${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}";
                      final id = DateTime.now().millisecondsSinceEpoch;

                      setState(() {
                        final newAlert = AlertEntry(
                          id: id.toDouble(),
                          type: t,
                          bus: b.isNotEmpty ? b : "all",
                          msg: m,
                          time: timeNow,
                        );
                        _alerts.insert(0, newAlert); // Insert at the top so it's the latest
                        _saveAlerts();
                      });

                      // Push to Firebase — student portals listen to student_notifications
                      if (Firebase.apps.isNotEmpty) {
                        FirebaseDatabase.instance
                            .ref('student_notifications/$id')
                            .set({
                          'type': t,
                          'title': title,
                          'msg': m,
                          'bus': b.isNotEmpty ? b : "all",
                          'time': timeNow,
                          'read': false,
                          'sentAt': DateTime.now().toIso8601String(),
                        });
                        // Also write to legacy routeAlerts path
                        FirebaseDatabase.instance
                            .ref('routeAlerts/$id')
                            .set({'type': t, 'bus': b, 'msg': m, 'time': timeNow});
                      }

                      Navigator.pop(context);
                      _showAppSnackBar("✅ Notification sent to all students!");
                    },
                  ),
                  SizedBox(height: 20),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String _defaultNotifTitle(String type) {
    switch (type) {
      case 'delay':        return 'Bus Delay Alert';
      case 'route_change': return 'Route Change Notice';
      case 'emergency':    return 'Emergency Alert';
      case 'arrival':      return 'Bus Arrival Notice';
      case 'breakdown':    return 'Bus Breakdown Alert';
      default:             return 'Transit Notice';
    }
  }

  Widget _buildViewerWidget(String? base64Data, String docUrl, String docName) {
    String? finalBase64 = base64Data;
    if (docUrl.startsWith("data:") || docUrl.length > 500) {
      finalBase64 = docUrl;
    }

    if (finalBase64 != null && finalBase64.isNotEmpty) {
      try {
        String cleanBase64 = finalBase64;
        if (cleanBase64.contains(',')) {
          cleanBase64 = cleanBase64.split(',').last;
        }
        cleanBase64 = cleanBase64.replaceAll(RegExp(r'\s+'), '');
        final bytes = base64Decode(cleanBase64);

        if (docName.toLowerCase().endsWith('.pdf') || finalBase64.startsWith('data:application/pdf')) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(15),
            child: SfPdfViewer.memory(
              bytes,
              canShowScrollHead: false,
              canShowScrollStatus: false,
            ),
          );
        } else {
          return ClipRRect(
            borderRadius: BorderRadius.circular(15),
            child: Image.memory(
              bytes,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return Center(child: Icon(Icons.broken_image, size: 40, color: Colors.grey));
              },
            ),
          );
        }
      } catch (e) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 40, color: Colors.red),
              SizedBox(height: 8),
              Text(t('Error decoding document'), style: TextStyle(fontSize: 12, color: Colors.red, fontWeight: FontWeight.bold)),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(e.toString(), textAlign: TextAlign.center, style: const TextStyle(fontSize: 9, color: Colors.grey)),
              ),
            ],
          ),
        );
      }
    } else if (docUrl.startsWith("http")) {
      if (docName.toLowerCase().endsWith('.pdf')) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: SfPdfViewer.network(
            docUrl,
            canShowScrollHead: false,
            canShowScrollStatus: false,
          ),
        );
      } else {
        return ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: Image.network(
            docUrl,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return Center(child: Icon(Icons.broken_image, size: 40, color: Colors.grey));
            },
          ),
        );
      }
    } else {
      if (docUrl.isEmpty) {
        return Center(child: Text(t('No document provided'), style: TextStyle(color: Colors.grey, fontSize: 12)));
      }
      return Center(
        child: CircularProgressIndicator(),
      );
    }
  }

  void _viewUploadedLetter(String docName, String docUrl) {
    showDialog(
      context: context,
      builder: (ctx) {
        final isDirect = docUrl.startsWith("http") || docUrl.startsWith("data:") || docUrl.length > 500;
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: isDirect
            ? Container(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(t('Document Preview'),
                            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1E3A8A)),
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.close, size: 20),
                          onPressed: () => Navigator.pop(ctx),
                        )
                      ],
                    ),
                    SizedBox(height: 16),
                    Container(
                      height: 400,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFCBD5E1)),
                      ),
                      child: _buildViewerWidget(null, docUrl, docName),
                    ),
                    SizedBox(height: 16),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF1F5F9),
                        foregroundColor: const Color(0xFF1E293B),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(t('Close Preview'), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    )
                  ],
                ),
              )
            : FutureBuilder<DataSnapshot>(
            future: FirebaseDatabase.instance.ref('documents/$docUrl').get(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return SizedBox(
                  height: 200,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              
              String? base64Data;
              if (snapshot.hasData && snapshot.data!.value != null) {
                final map = snapshot.data!.value as Map;
                base64Data = map['fileBase64'] as String?;
              }
              
              return Container(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(t('Document Preview'),
                            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1E3A8A)),
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.close, size: 20),
                          onPressed: () => Navigator.pop(ctx),
                        )
                      ],
                    ),
                    SizedBox(height: 16),
                    Container(
                      height: 400,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFCBD5E1)),
                      ),
                      child: _buildViewerWidget(base64Data, docUrl, docName),
                    ),
                    SizedBox(height: 16),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF1F5F9),
                        foregroundColor: const Color(0xFF1E293B),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(t('Close Preview'), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    )
                  ],
                ),
              );
            }
          ),
        );
      },
    );
  }



  @override
  Widget build(BuildContext context) {
    final List<Widget> tabs = [
      _buildOverviewTab(),
      _buildLiveTrackTab(),
      _buildSTTIntercomTab(),
      _buildRequestsTab(),
      _buildRegistryTab(),
      _buildAnnouncementsTab(),
    ];

    return Scaffold(
      backgroundColor: const Color(0xFFEEF2FF),
      appBar: AppBar(
        backgroundColor: Colors.white,
        scrolledUnderElevation: 0,
        elevation: 0,
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: const Color(0xFFBFDBFE)),
              ),
              child: Icon(Icons.admin_panel_settings, color: Color(0xFF2563EB), size: 22),
            ),
            SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(t('appTitle'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Color(0xFF0F172A)), overflow: TextOverflow.ellipsis),
                  Text(t('admin_subtitle'), style: TextStyle(fontSize: 9, color: Color(0xFF64748B), fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
                ],
              ),
            )
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: Icon(Icons.language, color: Color(0xFF2563EB)),
            onSelected: (String lang) {
              widget.onLanguageChanged(lang);
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(
                value: 'en',
                child: Text('English'),
              ),
              const PopupMenuItem<String>(
                value: 'ta',
                child: Text('தமிழ்'),
              ),
            ],
          ),
          Stack(
            children: [
              IconButton(
                icon: Icon(Icons.notifications, color: Color(0xFF2563EB), size: 30),
                onPressed: _showBreakdownNotifications,
              ),
              if (_adminUnreadCount > 0)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '$_adminUnreadCount',
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
                )
            ],
          ),
        ],
      ),
      body: tabs[_currentTab],
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFE2E8F0), width: 1.2))),
        child: NavigationBarTheme(
          data: NavigationBarThemeData(
            labelTextStyle: MaterialStateProperty.all(
              const TextStyle(fontSize: 10, overflow: TextOverflow.ellipsis),
            ),
          ),
          child: NavigationBar(
            backgroundColor: Colors.white,
            indicatorColor: const Color(0xFFEFF6FF),
            selectedIndex: _currentTab,
            onDestinationSelected: (idx) {
              setState(() {
                _currentTab = idx;
              });
            },
            destinations: [
            NavigationDestination(icon: Icon(Icons.analytics_outlined, color: Color(0xFF64748B)), selectedIcon: Icon(Icons.analytics, color: Color(0xFF2563EB)), label: t('admin_overview')),
            NavigationDestination(icon: Icon(Icons.map_outlined, color: Color(0xFF64748B)), selectedIcon: Icon(Icons.map, color: Color(0xFF2563EB)), label: t('admin_live_tracker')),
            NavigationDestination(icon: Icon(Icons.chat_bubble_outline, color: Color(0xFF64748B)), selectedIcon: Icon(Icons.chat_bubble, color: Color(0xFF2563EB)), label: t('admin_intercom')),
            NavigationDestination(icon: Icon(Icons.checklist_rtl_outlined, color: Color(0xFF64748B)), selectedIcon: Icon(Icons.checklist_rtl, color: Color(0xFF2563EB)), label: t('admin_approvals')),
            NavigationDestination(icon: Icon(Icons.app_registration_outlined, color: Color(0xFF64748B)), selectedIcon: Icon(Icons.app_registration, color: Color(0xFF2563EB)), label: t('admin_registry')),
            NavigationDestination(icon: Icon(Icons.campaign_outlined, color: Color(0xFF64748B)), selectedIcon: Icon(Icons.campaign, color: Color(0xFF2563EB)), label: 'Updates'),
          ],
          ),
        ),
      ),
    );
  }

  // ─── TABS IMPLEMENTATION ──────────────────────────────────────────
  Widget _buildOverviewTab() {
    int activeBuses = _liveBuses.values.where((v) {
      if (v['status'] == 'offline' || v['status'] == 'completed') return false;
      final u = v['updatedAt'];
      if (u == null) return false;
      try {
        final dt = DateTime.parse(u.toString()).toLocal();
        return DateTime.now().difference(dt).inMinutes < 15; // Only recently updated are active
      } catch (_) {
        return false;
      }
    }).length;
    int pendingReqs = _requests.where((r) => r['status'] == 'pending').length;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: _buildStatCard("🚌", "$activeBuses online", "Live Active Fleet", const Color(0xFF2563EB))),
              SizedBox(width: 8),
              Expanded(child: _buildStatCard("🎫", "$pendingReqs pending", "Pickup Letters Queue", const Color(0xFFEAB308))),
            ],
          ),
          SizedBox(height: 16),

          // Automated Logs Card
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            elevation: 2,
            shadowColor: Colors.black12,
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => AutomatedLogsScreen(
                      currentLang: widget.currentLang,
                    ),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.list_alt, color: Color(0xFF64748B)),
                        SizedBox(width: 12),
                        Text(t('📍 AUTOMATED LOGS'),
                          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Color(0xFF64748B), letterSpacing: 1),
                        ),
                      ],
                    ),
                    Icon(Icons.chevron_right, color: Colors.grey),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(height: 16),

          // Suggest stops card
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            elevation: 2,
            shadowColor: Colors.black12,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t('📍 DRIVER LOCATION STOP CAPTURE CONSOLE'),
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11, color: Color(0xFF2563EB), letterSpacing: 1),
                  ),
                  SwitchListTile(
                    title: Text(t('admin_allow_stops'), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF0F172A))),
                    subtitle: Text(t('admin_enable_stops_desc'), style: TextStyle(fontSize: 10, color: Color(0xFF64748B))),
                    value: _allowDriversToAddStops,
                    activeThumbColor: const Color(0xFF2563EB),
                    onChanged: (val) {
                      if (Firebase.apps.isNotEmpty) {
                        FirebaseDatabase.instance.ref('adminSettings/allowDriversToAddStops').set(val);
                      }
                    },
                  ),
                  if (_newStops.isNotEmpty) ...[
                    Divider(),
                    SizedBox(height: 8),
                    Text(t('admin_suggested_stops'), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF334155))),
                    SizedBox(height: 8),
                    _buildGroupedStopsWidget(),
                  ] else
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(child: Text(t('No location stop check-ins received yet.'), style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold))),
                    ),
                  SizedBox(height: 8),
                ],
              ),
            ),
          ),
          SizedBox(height: 16),



          // Active Alerts List Preview
          // Special Bus Schedule
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            elevation: 2,
            shadowColor: Colors.black12,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('🚌 SPECIAL BUS SCHEDULE',
                        style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11, color: Color(0xFF64748B), letterSpacing: 1),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.add, size: 14),
                        label: const Text('Add Bus', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                        onPressed: _openSpecialBusAddBottomSheet,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_specialBuses.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(child: Text('No special buses configured.', style: TextStyle(fontSize: 12, color: Colors.grey))),
                    )
                  else
                    ..._specialBuses.map((sb) => _buildSpecialBusCard(sb)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _autoSyncCapturedStopsToRouteRegistry(List<Map<String, dynamic>> stopsList, {bool showFeedback = false}) async {
    if (stopsList.isEmpty) return;

    // Group stops by bus in chronological order
    final Map<String, List<Map<String, dynamic>>> busStopsMap = {};
    for (var stop in stopsList) {
      final bus = stop['driverBus']?.toString().trim() ?? '';
      if (bus.isNotEmpty) {
        busStopsMap.putIfAbsent(bus, () => []).add(stop);
      }
    }

    bool routesChanged = false;

    for (var bus in busStopsMap.keys) {
      final stops = busStopsMap[bus]!;
      // Sort chronologically (earliest to latest = travel sequence from departure to terminus)
      stops.sort((a, b) => (a['timestamp'] as int? ?? 0).compareTo(b['timestamp'] as int? ?? 0));

      final List<String> formattedCapturedStops = [];
      for (var s in stops) {
        final name = s['stopName']?.toString().trim() ?? '';
        final lat = s['lat'];
        final lng = s['lng'];
        if (name.isNotEmpty && lat != null && lng != null) {
          formattedCapturedStops.add("$name (Lat: $lat, Lng: $lng)");
        } else if (name.isNotEmpty) {
          formattedCapturedStops.add(name);
        } else if (lat != null && lng != null) {
          formattedCapturedStops.add("Lat: $lat, Lng: $lng");
        }
      }

      if (formattedCapturedStops.isEmpty) continue;

      // Determine route key & name
      final cleanBusNum = bus.replaceAll(RegExp(r'[^0-9a-zA-Z]'), '');
      final driver = _drivers.firstWhere(
        (d) => d.bus.trim().toUpperCase() == bus.toUpperCase() ||
               d.bus.replaceAll(RegExp(r'[^0-9a-zA-Z]'), '') == cleanBusNum,
        orElse: () => DriverEntry(id: 0, bus: '', driver: '', route: '', type: ''),
      );

      String targetRouteKey = driver.route.isNotEmpty ? driver.route : "route_$cleanBusNum";
      String targetRouteName = driver.route.isNotEmpty 
          ? _getRouteDisplayName(driver.route) 
          : "Route $bus";

      final idx = _routes.indexWhere((r) => r.key.toLowerCase() == targetRouteKey.toLowerCase() ||
                                            r.key.toLowerCase() == "route_$cleanBusNum".toLowerCase() ||
                                            r.name.toLowerCase().contains("route $cleanBusNum".toLowerCase()) ||
                                            r.name.toLowerCase().contains("bus $cleanBusNum".toLowerCase()));

      if (idx != -1) {
        // Merge or update stops in correct travel order
        final existingStops = List<String>.from(_routes[idx].stops);
        for (var newStop in formattedCapturedStops) {
          final cleanNew = _cleanStopName(newStop).toLowerCase();
          final exists = existingStops.any((s) => _cleanStopName(s).toLowerCase() == cleanNew);
          if (!exists) {
            existingStops.add(newStop);
          }
        }
        if (existingStops.length != _routes[idx].stops.length) {
          _routes[idx] = RouteEntry(
            id: _routes[idx].id,
            key: _routes[idx].key,
            name: _routes[idx].name,
            stops: healRouteStops(existingStops),
            color: _routes[idx].color,
          );
          routesChanged = true;
        }
      }
      // NOTE: Do NOT create new routes here — only the admin can create routes explicitly
    }

    if (routesChanged) {
      if (mounted) setState(() {});
      _saveRoutes();
    }

    if (showFeedback && mounted) {
      _showAppSnackBar("✅ Route Registry updated with captured stops!");
    }
  }

  Widget _buildGroupedStopsWidget() {
    // Group stops by driverBus
    final Map<String, List<Map<String, dynamic>>> grouped = {};
    for (var stop in _newStops) {
      final bus = stop['driverBus']?.toString() ?? 'Unknown Bus';
      grouped.putIfAbsent(bus, () => []).add(stop);
    }

    return Column(
      children: [
        for (var bus in grouped.keys) ...[
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            margin: const EdgeInsets.symmetric(vertical: 6),
            borderOnForeground: true,
            elevation: 0,
            color: const Color(0xFFF8FAFC),
            child: ExpansionTile(
              initiallyExpanded: true,
              leading: const CircleAvatar(
                backgroundColor: Color(0xFFDBEAFE),
                child: Icon(Icons.directions_bus, color: Color(0xFF2563EB), size: 18),
              ),
              title: Row(
                children: [
                  Text("Bus $bus", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF1E3A8A))),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDCFCE7),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text("In Route Registry", style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w900, color: Color(0xFF16A34A))),
                  ),
                ],
              ),
              subtitle: Text("${grouped[bus]!.length} stops check-ins", style: const TextStyle(fontSize: 10, color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
              childrenPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("📍 Sequence (Departure ➔ Terminus)", style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.sync, size: 13),
                        label: const Text("Sync to Registry", style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2563EB),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                          elevation: 0,
                          minimumSize: const Size(0, 28),
                        ),
                        onPressed: () {
                          _autoSyncCapturedStopsToRouteRegistry(grouped[bus]!, showFeedback: true);
                        },
                      ),
                    ],
                  ),
                ),
                ...grouped[bus]!.asMap().entries.map((entry) {
                  final idx = entry.key;
                  final stop = entry.value;
                  final ts = stop['timestamp'] as int?;
                  final timeStr = ts != null ? DateTime.fromMillisecondsSinceEpoch(ts).toString().substring(0, 16) : "--";
                  return Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 11,
                          backgroundColor: const Color(0xFFEEF2FF),
                          child: Text("${idx + 1}", style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Color(0xFF2563EB))),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                (stop['stopName'] != null && stop['stopName'].toString().isNotEmpty) 
                                    ? stop['stopName'].toString() 
                                    : "Lat: ${stop['lat']}, Lng: ${stop['lng']}",
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF0F172A))
                              ),
                              const SizedBox(height: 4),
                              Text("Captured: $timeStr", style: const TextStyle(fontSize: 9.5, color: Colors.grey, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                          onPressed: () async {
                            if (Firebase.apps.isNotEmpty) {
                              final cleanBusNum = (stop['driverBus']?.toString() ?? '').replaceAll(RegExp(r'[^0-9a-zA-Z]'), '');
                              final driver = _drivers.firstWhere(
                                (d) => d.bus == stop['driverBus'], 
                                orElse: () => DriverEntry(id: 0, bus: '', driver: '', route: '', type: ''),
                              );
                              final targetRoute = driver.route.isNotEmpty ? driver.route : "route_$cleanBusNum";
                              
                              if (targetRoute.isNotEmpty) {
                                final rRef = FirebaseDatabase.instance.ref('routes/$targetRoute');
                                final rSnap = await rRef.get();
                                if (rSnap.exists && rSnap.value != null) {
                                  final rData = Map<String, dynamic>.from(rSnap.value as Map);
                                  List<dynamic> stops = [];
                                  if (rData['stops'] != null) {
                                    stops = List.from(rData['stops'] as List);
                                  }
                                  
                                  // Remove by matching stopName or Lat/Lng
                                  final stopNameStr = stop['stopName']?.toString().toLowerCase().trim() ?? '';
                                  final latStr = "Lat: ${stop['lat']}";
                                  final lngStr = "Lng: ${stop['lng']}";
                                  stops.removeWhere((s) {
                                    final sLower = s.toString().toLowerCase();
                                    final cleanS = _cleanStopName(s.toString()).toLowerCase();
                                    return (stopNameStr.isNotEmpty && cleanS == stopNameStr) ||
                                           (sLower.contains(latStr.toLowerCase()) && sLower.contains(lngStr.toLowerCase()));
                                  });
                                  
                                  await rRef.update({'stops': stops});
                                  
                                  // Update memory _routes
                                  final rIdx = _routes.indexWhere((r) => r.key.toLowerCase() == targetRoute.toLowerCase());
                                  if (rIdx != -1) {
                                    setState(() {
                                      _routes[rIdx] = RouteEntry(
                                        id: _routes[rIdx].id,
                                        key: _routes[rIdx].key,
                                        name: _routes[rIdx].name,
                                        stops: List<String>.from(stops),
                                        color: _routes[rIdx].color,
                                      );
                                    });
                                    _saveRoutes();
                                  }
                                }
                              }
                              final fbKey = stop['_key']?.toString() ?? "${stop['driverBus']}_$ts";
                              await FirebaseDatabase.instance.ref('new_stops/$fbKey').remove();
                              if (mounted) {
                                _showAppSnackBar("Stop removed from check-ins and Route Registry.");
                              }
                            }
                          },
                        )
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        ]
      ],
    );
  }

  Widget _buildStatCard(String icon, String val, String title, Color color) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Color(0xFFE2E8F0))),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
              alignment: Alignment.center,
              child: Text(icon, style: const TextStyle(fontSize: 22)),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(val, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF0F172A))),
                  SizedBox(height: 2),
                  Text(title, style: const TextStyle(fontSize: 9.5, color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlertCard(AlertEntry a) {
    final isB = a.type == 'breakdown';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isB ? const Color(0xFFFEF2F2) : const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isB ? const Color(0xFFFCA5A5) : const Color(0xFFFDE68A)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(isB ? "🚨" : "⚠️", style: const TextStyle(fontSize: 18)),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Notice (${a.bus == 'all' ? 'All Buses' : 'Bus ${a.bus}'}) • ${a.time}", style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: isB ? const Color(0xFF991B1B) : const Color(0xFF92400E))),
                SizedBox(height: 4),
                Text(a.msg, style: TextStyle(fontSize: 11.5, color: isB ? const Color(0xFF7F1D1D) : const Color(0xFF78350F), fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 14),
            onPressed: () {
              setState(() {
                _alerts.removeWhere((item) => item.id == a.id);
                _saveAlerts();
              });
              if (Firebase.apps.isNotEmpty) {
                FirebaseDatabase.instance.ref('routeAlerts/${a.id.round()}').remove();
              }
            },
          )
        ],
      ),
    );
  }

  static final Map<String, LatLng> _stopCoordsRegistry = {};

  LatLng _getStopLatLng(String stop, [int sequenceIndex = 0]) {
    final RegExp regEx = RegExp(r'(?:Lat:\s*)?([-\d.]+)[,\s]+(?:Lng:\s*)?([-\d.]+)');
    final match = regEx.firstMatch(stop);
    if (match != null) {
      try {
        final lat = double.parse(match.group(1)!);
        final lng = double.parse(match.group(2)!);
        if (lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180) {
          final cleanKey = _cleanStopName(stop).toLowerCase();
          final coord = LatLng(lat, lng);
          if (cleanKey.isNotEmpty) _stopCoordsRegistry[cleanKey] = coord;
          return coord;
        }
      } catch (_) {}
    }

    final cleanName = _cleanStopName(stop).toLowerCase();

    if (cleanName.isNotEmpty && _stopCoordsRegistry.containsKey(cleanName)) {
      return _stopCoordsRegistry[cleanName]!;
    }

    final defaultCoords = <String, LatLng>{
      'hostel1': const LatLng(13.0500, 80.0742),
      'hostel2': const LatLng(13.0515, 80.0755),
      'hostel3': const LatLng(13.0530, 80.0768),
      'hostel4': const LatLng(13.0545, 80.0781),
      'hostel': const LatLng(13.0500, 80.0742),
      'panimalar engineering college': const LatLng(13.0489, 80.0755),
      'panimalar': const LatLng(13.0489, 80.0755),
      'pec': const LatLng(13.0489, 80.0755),
      'college': const LatLng(13.0489, 80.0755),
      'manali': const LatLng(13.1667, 80.2667),
      'porur': const LatLng(13.0382, 80.1565),
      'koyambedu': const LatLng(13.0732, 80.1982),
      'poonamallee': const LatLng(13.0495, 80.0934),
      'maduravoyal': const LatLng(13.0650, 80.1650),
      'avadi': const LatLng(13.1147, 80.1098),
      'ambattur': const LatLng(13.1143, 80.1548),
      'tambaram': const LatLng(12.9249, 80.1000),
      'guindy': const LatLng(13.0067, 80.2020),
      'velachery': const LatLng(12.9759, 80.2212),
      'chromepet': const LatLng(12.9516, 80.1462),
    };

    if (defaultCoords.containsKey(cleanName)) {
      final coord = defaultCoords[cleanName]!;
      if (cleanName.isNotEmpty) _stopCoordsRegistry[cleanName] = coord;
      return coord;
    }

    for (final entry in defaultCoords.entries) {
      if (cleanName.contains(entry.key) || entry.key.contains(cleanName)) {
        if (cleanName.isNotEmpty) _stopCoordsRegistry[cleanName] = entry.value;
        return entry.value;
      }
    }

    int hash = 0;
    final strToHash = cleanName.isNotEmpty ? cleanName : "stop_$sequenceIndex";
    for (int i = 0; i < strToHash.length; i++) {
      hash = 31 * hash + strToHash.codeUnitAt(i);
    }
    final latOffset = ((hash.abs() % 1000) - 500) / 100000.0;
    final lngOffset = (((hash.abs() ~/ 1000) % 1000) - 500) / 100000.0;
    final fallbackCoord = LatLng(13.0495 + latOffset, 80.0934 + lngOffset);
    if (cleanName.isNotEmpty) _stopCoordsRegistry[cleanName] = fallbackCoord;
    return fallbackCoord;
  }

  Widget _buildLiveTrackTab() {
    // Initial auto-select on a random active live tracking bus & set its route
    if (!_hasInitialMapAutoZoomed) {
      final activeLiveBuses = _liveBuses.entries.where((e) {
        final st = e.value['status'] as String? ?? 'offline';
        return st == 'tracking' || st == 'broken';
      }).toList();

      if (activeLiveBuses.isNotEmpty) {
        final targetBus = activeLiveBuses[Random().nextInt(activeLiveBuses.length)];
        final busId = targetBus.key;
        final double lat = (targetBus.value['lat'] as num).toDouble();
        final double lng = (targetBus.value['lng'] as num).toDouble();

        final driver = _drivers.firstWhere(
          (d) => d.bus.toLowerCase() == busId.toLowerCase() || d.bus.toLowerCase() == "bus $busId".toLowerCase(),
          orElse: () => DriverEntry(id: 0, bus: '', driver: '', route: '', type: ''),
        );

        if (driver.route.isNotEmpty) {
          final matchingRoute = _routes.firstWhere(
            (r) => r.key.toLowerCase() == driver.route.toLowerCase(),
            orElse: () => _routes.isNotEmpty ? _routes.first : RouteEntry(id: 0, key: '', name: '', stops: [], color: '#2563EB'),
          );
          if (matchingRoute.stops.isNotEmpty) {
            _selectedLiveRoute = matchingRoute;
          }
        } else if (_routes.isNotEmpty) {
          _selectedLiveRoute = _routes.first;
        }

        _hasInitialMapAutoZoomed = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _mapController.move(LatLng(lat, lng), 16.0);
        });
      } else if (_routes.isNotEmpty && _selectedLiveRoute == null) {
        _selectedLiveRoute = _routes.first;
      }
    }

    final List<Marker> markers = [];
    final List<Polyline> routePolylines = [];

    // 1. Add college campus pin
    markers.add(
      Marker(
        point: _campusCoord,
        width: 44,
        height: 44,
        child: Container(
          decoration: const BoxDecoration(color: Color(0xFF1E3A8A), shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 4)]),
          alignment: Alignment.center,
          child: Text(t(' PEC '), style: TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: Colors.white)),
        ),
      ),
    );

    // 2. Render route polylines for selected route (or all routes) without placing stop markers
    final routesToRender = _selectedLiveRoute != null ? [_selectedLiveRoute!] : _routes;
    for (var r in routesToRender) {
      final List<LatLng> stopPoints = [];
      for (int i = 0; i < r.stops.length; i++) {
        final stopStr = r.stops[i];
        final pos = _getStopLatLng(stopStr);
        if (pos != null) {
          stopPoints.add(pos);
        }
      }

      if (stopPoints.length > 1) {
        Color routeColor = const Color(0xFF2563EB);
        try {
          routeColor = Color(int.parse(r.color.replaceFirst('#', '0xFF')));
        } catch (_) {}
        routePolylines.add(
          Polyline(
            points: stopPoints,
            color: routeColor.withValues(alpha: 0.7),
            strokeWidth: 3.5,
          ),
        );
      }
    }

    // 3. Render live bus pins (only yellow bus image without circular container border)
    _liveBuses.forEach((busId, data) {
      final status = data['status'] as String? ?? 'offline';
      if (status == 'tracking' || status == 'broken') {
        if (_selectedLiveRoute != null) {
          final driver = _drivers.firstWhere(
            (d) => d.bus == busId, 
            orElse: () => DriverEntry(id: 0, bus: '', driver: '', route: '', type: '')
          );
          if (driver.route != _selectedLiveRoute!.key) {
            return;
          }
        }

        final double lat = (data['lat'] as num).toDouble();
        final double lng = (data['lng'] as num).toDouble();
        markers.add(
          Marker(
            point: LatLng(lat, lng),
            width: 70,
            height: 70,
            alignment: Alignment.bottomCenter,
            child: GestureDetector(
              onTap: () {
                _mapController.move(LatLng(lat, lng), 16.5);
              },
              child: Tooltip(
                message: "Bus $busId (${status.toUpperCase()})",
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: status == 'broken' ? const Color(0xFFDC2626) : const Color(0xFF16A34A),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: const [
                          BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
                        ],
                      ),
                      child: Text(
                        busId.startsWith("Bus") ? busId : "Bus $busId",
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.white),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Image.memory(
                      BusCardIcons.yellowBusBytes,
                      width: 46,
                      height: 46,
                      gaplessPlayback: true,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Icon(
                        Icons.directions_bus_rounded,
                        size: 38,
                        color: status == 'broken' ? const Color(0xFFDC2626) : const Color(0xFFEAB308),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
    });

    final query = _liveMapSearchQuery.toLowerCase();
    final List<Map<String, dynamic>> searchMatches = [];

    if (query.isNotEmpty) {
      for (var r in _routes) {
        String? activeBusId;
        String? activeStatus;
        double? activeLat;
        double? activeLng;

        _liveBuses.forEach((busId, data) {
          final status = data['status'] as String? ?? 'offline';
          if (status == 'tracking' || status == 'broken') {
            final driver = _drivers.firstWhere(
              (d) => d.bus.toLowerCase() == busId.toLowerCase() || d.bus.toLowerCase() == "bus $busId".toLowerCase(),
              orElse: () => DriverEntry(id: 0, bus: '', driver: '', route: '', type: ''),
            );
            if (driver.route.toLowerCase() == r.key.toLowerCase() ||
                r.key.toLowerCase().contains(busId.toLowerCase()) ||
                r.name.toLowerCase().contains(busId.toLowerCase())) {
              activeBusId = busId;
              activeStatus = status;
              activeLat = (data['lat'] as num).toDouble();
              activeLng = (data['lng'] as num).toDouble();
            }
          }
        });

        final matchesRouteName = r.name.toLowerCase().contains(query) || r.key.toLowerCase().contains(query);
        final matchesStops = r.stops.any((s) => s.toLowerCase().contains(query));
        final matchesBus = activeBusId != null && (activeBusId!.toLowerCase().contains(query) || "bus ${activeBusId!}".toLowerCase().contains(query));

        if (matchesRouteName || matchesStops || matchesBus) {
          final isLive = activeBusId != null;
          searchMatches.add({
            'type': isLive ? 'live_route' : 'basic_route',
            'route': r,
            'busId': activeBusId,
            'status': activeStatus,
            'lat': activeLat,
            'lng': activeLng,
            'title': isLive 
                ? '${r.name} (Live Tracking)' 
                : r.name,
            'subtitle': isLive 
                ? 'Bus ${activeBusId!} Active • Click to view live tracking & route' 
                : '${r.stops.length} stops • Click to view route',
          });
        }
      }
    }

    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              FlutterMap(
                mapController: _mapController,
                options: const MapOptions(
                  initialCenter: LatLng(13.047, 80.11),
                  initialZoom: 12.0,
                ),
                children: [
                  TileLayer(
                    urlTemplate: 'https://mt{s}.google.com/vt/lyrs=m&x={x}&y={y}&z={z}',
                    subdomains: const ['0', '1', '2', '3'],
                    userAgentPackageName: 'com.panimalar.bus',
                    maxNativeZoom: 19,
                    maxZoom: 22.0,
                    keepBuffer: 5,
                    panBuffer: 2,
                  ),
                  MarkerLayer(markers: markers),
                ],
              ),

              Positioned(
                top: 16,
                left: 16,
                right: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, 4))],
                      ),
                      child: TextField(
                        controller: _liveMapSearchCtrl,
                        onChanged: (val) {
                          setState(() {
                            _liveMapSearchQuery = val;
                          });
                        },
                        decoration: InputDecoration(
                          hintText: t('searchLiveRouteHint'),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          border: InputBorder.none,
                          suffixIcon: _liveMapSearchQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, color: Colors.grey),
                                  onPressed: () {
                                    _liveMapSearchCtrl.clear();
                                    setState(() {
                                      _liveMapSearchQuery = "";
                                    });
                                  },
                                )
                              : null,
                          icon: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEFF6FF),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.search_rounded, size: 20, color: Color(0xFF2563EB)),
                          ),
                        ),
                      ),
                    ),
                    
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 36,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _routes.length + 1,
                        separatorBuilder: (_, __) => const SizedBox(width: 6),
                        itemBuilder: (ctx, idx) {
                          if (idx == 0) {
                            final isAll = _selectedLiveRoute == null;
                            return ChoiceChip(
                              label: const Text("All Routes", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                              selected: isAll,
                              selectedColor: const Color(0xFF1E3A8A),
                              backgroundColor: Colors.white,
                              labelStyle: TextStyle(color: isAll ? Colors.white : const Color(0xFF1E3A8A)),
                              onSelected: (_) {
                                setState(() {
                                  _selectedLiveRoute = null;
                                  _liveMapSearchCtrl.clear();
                                });
                              },
                            );
                          }
                          final r = _routes[idx - 1];
                          final isSelected = _selectedLiveRoute?.key == r.key;
                          return ChoiceChip(
                            label: Text(r.name, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            selected: isSelected,
                            selectedColor: const Color(0xFF2563EB),
                            backgroundColor: Colors.white,
                            labelStyle: TextStyle(color: isSelected ? Colors.white : const Color(0xFF1E293B)),
                            onSelected: (_) {
                              setState(() {
                                _selectedLiveRoute = r;
                                _liveMapSearchCtrl.text = r.name;
                              });
                              LatLng? targetCoord;
                              _liveBuses.forEach((busId, data) {
                                final status = data['status'] as String? ?? 'offline';
                                if (status == 'tracking' || status == 'broken') {
                                  final driver = _drivers.firstWhere(
                                    (d) => d.bus == busId,
                                    orElse: () => DriverEntry(id: 0, bus: '', driver: '', route: '', type: ''),
                                  );
                                  if (driver.route == r.key) {
                                    targetCoord = LatLng((data['lat'] as num).toDouble(), (data['lng'] as num).toDouble());
                                  }
                                }
                              });
                              if (targetCoord != null) {
                                _mapController.move(targetCoord!, 16.0);
                              } else if (r.stops.isNotEmpty) {
                                final pos = _getStopLatLng(r.stops.first);
                                if (pos != null) _mapController.move(pos, 15.5);
                              }
                            },
                          );
                        },
                      ),
                    ),

                    if (_liveMapSearchQuery.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(top: 8),
                        constraints: const BoxConstraints(maxHeight: 250),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, 4))],
                        ),
                        child: searchMatches.isEmpty
                            ? Padding(padding: const EdgeInsets.all(16), child: Text(t('No routes found'), style: const TextStyle(color: Colors.grey)))
                            : ListView.separated(
                                shrinkWrap: true,
                                itemCount: searchMatches.length,
                                separatorBuilder: (_, _) => const Divider(height: 1),
                                itemBuilder: (ctx, idx) {
                                  final item = searchMatches[idx];
                                  final isLive = item['type'] == 'live_route';
                                  final status = item['status'] as String? ?? 'offline';
                                  return Material(
                                    color: Colors.transparent,
                                    child: ListTile(
                                      leading: Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: isLive
                                              ? (status == 'broken' ? const Color(0xFFFEE2E2) : const Color(0xFFDCFCE7))
                                              : const Color(0xFFEFF6FF),
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                          Icons.directions_bus_rounded,
                                          color: isLive
                                              ? (status == 'broken' ? const Color(0xFFDC2626) : const Color(0xFF16A34A))
                                              : const Color(0xFF2563EB),
                                          size: 22,
                                        ),
                                      ),
                                      title: Text(
                                        item['title'],
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                      ),
                                      subtitle: Text(
                                        item['subtitle'],
                                        style: const TextStyle(fontSize: 11, color: Colors.grey),
                                      ),
                                      onTap: () {
                                        setState(() {
                                          _liveMapSearchQuery = "";
                                          final r = item['route'] as RouteEntry;
                                          _selectedLiveRoute = r;
                                          _liveMapSearchCtrl.text = item['title'];

                                          if (item['lat'] != null && item['lng'] != null) {
                                            final coord = LatLng(item['lat'], item['lng']);
                                            _mapController.move(coord, 16.5);
                                          } else if (r.stops.isNotEmpty) {
                                            final pos = _getStopLatLng(r.stops.first);
                                            if (pos != null) {
                                              _mapController.move(pos, 15.5);
                                            }
                                          }
                                        });
                                      },
                                    ),
                                  );
                                },
                              ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSTTIntercomTab() {
    if (_selectedIntercomBus == null) {
      return _buildChatList();
    } else {
      return _buildChatScreen();
    }
  }

  Widget _buildChatList() {
    // Only include active routes currently in Route Registry (_routes) & Driver Registry (_drivers)
    final Set<String> activeBusIds = {};
    for (final r in _routes) {
      final cleanKey = r.key.replaceAll(RegExp(r'[^0-9]'), '');
      if (cleanKey.isNotEmpty) {
        activeBusIds.add(cleanKey);
      } else {
        final cleanName = r.name.replaceAll(RegExp(r'[^0-9]'), '');
        if (cleanName.isNotEmpty) {
          activeBusIds.add(cleanName);
        } else {
          final stripped = r.key.replaceFirst('route_', '').trim();
          if (stripped.isNotEmpty) activeBusIds.add(stripped);
        }
      }
    }
    for (final d in _drivers) {
      if (d.bus.trim().isNotEmpty) {
        activeBusIds.add(d.bus.trim());
      }
    }

    final query = _intercomSearchQuery.toLowerCase();
    final filteredBusIds = activeBusIds.where((bus) => bus.toLowerCase().contains(query)).toList();

    // Sort hierarchy:
    // 1. UNREAD CHATS ALWAYS AT THE ABSOLUTE TOP (sorted by newest timestamp / unread count)
    // 2. READ CHATS WITH MESSAGES (sorted by newest timestamp descending)
    // 3. INACTIVE ROUTES WITH NO MESSAGES (sorted numerically)
    filteredBusIds.sort((a, b) {
      final unreadA = _unreadPerBus[a] ?? 0;
      final unreadB = _unreadPerBus[b] ?? 0;

      // Tier 1: Unread vs Read
      if (unreadA > 0 && unreadB == 0) return -1;
      if (unreadA == 0 && unreadB > 0) return 1;

      final msgsA = _adminIntercomMessages['driver_$a'] ?? [];
      final msgsB = _adminIntercomMessages['driver_$b'] ?? [];
      final int tsA = msgsA.isNotEmpty ? (msgsA.last['timestamp'] as int? ?? 0) : 0;
      final int tsB = msgsB.isNotEmpty ? (msgsB.last['timestamp'] as int? ?? 0) : 0;

      // If both are unread:
      if (unreadA > 0 && unreadB > 0) {
        if (tsA != tsB) return tsB.compareTo(tsA);
        return unreadB.compareTo(unreadA);
      }

      // Tier 2: Read messages vs No messages
      if (tsA > 0 && tsB == 0) return -1;
      if (tsA == 0 && tsB > 0) return 1;

      if (tsA > 0 && tsB > 0) {
        if (tsA != tsB) return tsB.compareTo(tsA);
      }

      // Tier 3: No messages -> sort numerically
      final numA = int.tryParse(a) ?? 999999;
      final numB = int.tryParse(b) ?? 999999;
      if (numA != numB) return numA.compareTo(numB);
      return a.compareTo(b);
    });

    return Container(
      color: Colors.white,
      child: Column(
        children: [
          // Header & Search
          Container(
            color: const Color(0xFFF0F2F5), // WhatsApp light grey top
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: TextField(
                controller: _intercomSearchCtrl,
                onChanged: (val) => setState(() => _intercomSearchQuery = val),
                decoration: const InputDecoration(
                  hintText: "Search messages",
                  hintStyle: TextStyle(fontSize: 14, color: Colors.grey),
                  prefixIcon: Icon(Icons.search, size: 20, color: Colors.grey),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 14),
                ),
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ),
          Divider(height: 1, thickness: 1, color: Color(0xFFE0E0E0)),
          
          // Chat List
          Expanded(
            child: filteredBusIds.isEmpty
                ? Center(child: Padding(padding: EdgeInsets.all(16.0), child: Text(t('No active drivers found.'), style: TextStyle(fontSize: 13, color: Colors.grey))))
                : ListView.separated(
                    itemCount: filteredBusIds.length,
                    separatorBuilder: (ctx, idx) => Divider(height: 1, indent: 80, color: Color(0xFFF0F0F0)),
                    itemBuilder: (ctx, idx) {
                      final bus = filteredBusIds[idx];
                      final msgs = _adminIntercomMessages['driver_$bus'] ?? [];
                      
                      String lastMsg = "";
                      String timeStr = "";
                      if (msgs.isNotEmpty) {
                        final last = msgs.last;
                        lastMsg = (last['isVoice'] == true) 
                            ? "🎤 Voice message" 
                            : (last['msg'] ?? '');
                        
                        final ts = last['timestamp'] as int?;
                        if (ts != null) {
                          final dt = DateTime.fromMillisecondsSinceEpoch(ts);
                          timeStr = "${dt.hour > 12 ? dt.hour - 12 : dt.hour}:${dt.minute.toString().padLeft(2, '0')} ${dt.hour >= 12 ? 'pm' : 'am'}";
                        }
                      }
                      
                      final unreadCount = _unreadPerBus[bus] ?? 0;

                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        tileColor: Colors.white,
                        leading: CircleAvatar(
                          radius: 26,
                          backgroundColor: Colors.blueGrey[100],
                          backgroundImage: const NetworkImage("https://ui-avatars.com/api/?name=Bus&background=random&color=fff"),
                          child: Icon(Icons.directions_bus, color: Colors.white, size: 24),
                        ),
                        title: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text("Route $bus", style: TextStyle(
                              fontWeight: unreadCount > 0 ? FontWeight.bold : FontWeight.bold,
                              fontSize: 16,
                              color: Colors.black87,
                            )),
                            Text(timeStr, style: TextStyle(
                              fontSize: 12,
                              color: unreadCount > 0 ? const Color(0xFF25D366) : Colors.grey,
                              fontWeight: unreadCount > 0 ? FontWeight.bold : FontWeight.normal,
                            )),
                          ],
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  lastMsg.isEmpty ? "Tap to start messaging" : lastMsg,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: unreadCount > 0 ? Colors.black87 : Colors.black54,
                                    fontWeight: unreadCount > 0 ? FontWeight.w600 : FontWeight.normal,
                                  ),
                                ),
                              ),
                              if (unreadCount > 0) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                  decoration: const BoxDecoration(
                                    color: Color(0xFF25D366),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Text(
                                    unreadCount > 99 ? '99+' : '$unreadCount',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        onTap: () {
                          // Mark as read in Firebase Realtime Database
                          _markMessagesAsRead(bus);
                          setState(() {
                            _unreadPerBus.remove(bus);
                            _selectedIntercomBus = bus;
                          });
                        },
                      );
                    },
                  ),
          )
        ],
      ),
    );
  }

  Widget _buildChatScreen() {
    return Column(
      children: [
        // Chat Header
        Container(
          color: const Color(0xFFF0F2F5),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.meeting_room_outlined, color: Color(0xFF1E293B), size: 22),
                tooltip: "Close Chat",
                onPressed: () {
                  if (_selectedIntercomBus != null) {
                    _markMessagesAsRead(_selectedIntercomBus!);
                  }
                  setState(() {
                    _unreadPerBus.remove(_selectedIntercomBus);
                    _selectedIntercomBus = null;
                  });
                },
              ),
              CircleAvatar(
                backgroundColor: Colors.blueGrey[100],
                backgroundImage: const NetworkImage("https://ui-avatars.com/api/?name=Bus&background=random&color=fff"),
                child: Icon(Icons.directions_bus, color: Colors.white, size: 20),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Route $_selectedIntercomBus", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87)),
                    Text(t('admin_online'), style: const TextStyle(fontSize: 13, color: Colors.black54)),
                  ],
                ),
              ),
              IconButton(icon: Icon(Icons.search, color: Colors.black54), onPressed: () {}),
              IconButton(icon: Icon(Icons.more_vert, color: Colors.black54), onPressed: () {}),
            ],
          ),
        ),
        
        // Chat Messages
        Expanded(
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xFFE5DDD5),
              image: DecorationImage(
                image: NetworkImage("https://user-images.githubusercontent.com/15075759/28719144-86dc0f70-73b1-11e7-911d-60d70fcded21.png"),
                fit: BoxFit.cover,
                opacity: 0.3,
              ),
            ),
            child: Builder(builder: (ctx) {
              final msgs = List<Map<String, dynamic>>.from(
                _adminIntercomMessages['driver_$_selectedIntercomBus'] ?? [],
              );
              // Newest at bottom — messages already sorted ascending so just show them
              return ListView.builder(
                controller: _chatScrollController,
                padding: const EdgeInsets.all(16),
                itemCount: msgs.length,
                itemBuilder: (ctx, idx) {
                  final m = msgs[idx];
                  final isMe = m['sender'] == 'admin';
                  final isVoice = m['isVoice'] == true;

                  String msgTime = "";
                  final ts = m['timestamp'] as int?;
                  if (ts != null) {
                     final dt = DateTime.fromMillisecondsSinceEpoch(ts);
                     msgTime = "${dt.hour > 12 ? dt.hour - 12 : dt.hour}:${dt.minute.toString().padLeft(2, '0')} ${dt.hour >= 12 ? 'pm' : 'am'}";
                  }

                  return GestureDetector(
                    onLongPress: () {
                      showModalBottomSheet(
                        context: context,
                        backgroundColor: Colors.white,
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                        ),
                        builder: (_) => SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(height: 8),
                              Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                              const SizedBox(height: 16),
                              ListTile(
                                leading: const Icon(Icons.delete, color: Colors.red),
                                title: const Text("Delete Message", style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
                                onTap: () async {
                                  Navigator.pop(context);
                                  try {
                                    await FirebaseDatabase.instance
                                        .ref('voice_messages/driver_$_selectedIntercomBus/${m['id']}')
                                        .remove();
                                  } catch (e) {
                                    _showAppSnackBar("Error deleting message: $e");
                                  }
                                },
                              ),
                              ListTile(
                                leading: const Icon(Icons.cancel, color: Colors.black54),
                                title: const Text("Cancel"),
                                onTap: () => Navigator.pop(context),
                              ),
                              const SizedBox(height: 8),
                            ],
                          ),
                        ),
                      );
                    },
                    child: Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        width: isVoice ? 240 : null,
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                        decoration: BoxDecoration(
                          color: isMe ? const Color(0xFFD9FDD3) : Colors.white,
                          borderRadius: BorderRadius.circular(12).copyWith(
                            topRight: isMe ? const Radius.circular(0) : const Radius.circular(12),
                            topLeft: isMe ? const Radius.circular(12) : const Radius.circular(0),
                          ),
                          boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 1, offset: Offset(0, 1))],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            if (isVoice)
                              Row(
                                children: [
                                  InkWell(
                                    onTap: () {
                                      _playVoiceMessage(m['id'], m['mongoId'] ?? '', m['voiceDuration'] ?? 3);
                                    },
                                    child: Icon(
                                      _playingMsgId == m['id'] ? Icons.stop_circle : Icons.play_arrow,
                                      color: Colors.grey[700],
                                      size: 32,
                                    ),
                                  ),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: LinearProgressIndicator(
                                      value: _playingMsgId == m['id'] ? _playbackProgress : 0.0,
                                      backgroundColor: Colors.black12,
                                      valueColor: AlwaysStoppedAnimation(Colors.grey[700]),
                                    ),
                                  ),
                                  SizedBox(width: 8),
                                  Text("0:${(m['voiceDuration'] ?? 3).toString().padLeft(2, '0')}", style: const TextStyle(fontSize: 12, color: Colors.black54)),
                                ],
                              )
                            else
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Text("${m['msg']}", style: const TextStyle(fontSize: 15, color: Colors.black87)),
                              ),
                            SizedBox(height: 2),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(msgTime, style: const TextStyle(fontSize: 10, color: Colors.black54)),
                                if (isMe) ...[
                                   SizedBox(width: 4),
                                   Icon(Icons.done_all, size: 14, color: Colors.blue),
                                ]
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            }),
          ),
        ),
        
        // Chat Input
        if (_isRecordingVoice)
          Container(
            color: const Color(0xFFF0F2F5),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(Icons.delete, color: Colors.red, size: 28),
                  onPressed: _cancelRecordingVoice,
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Text(
                    "Recording... 0:${_recordingDurationSecs.toString().padLeft(2, '0')}",
                    style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                ),
                SizedBox(width: 16),
                IconButton(
                  icon: Icon(Icons.send, color: Color(0xFF00A884), size: 28),
                  onPressed: _stopAndSendRecordingVoice,
                ),
              ],
            ),
          )
        else
          Container(
            color: const Color(0xFFF0F2F5),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.emoji_emotions_outlined, color: Colors.black54, size: 28),
                SizedBox(width: 10),
                Icon(Icons.attach_file, color: Colors.black54, size: 28),
                SizedBox(width: 10),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: TextField(
                      controller: _adminChatInputCtrl,
                      decoration: const InputDecoration(
                        hintText: "Type a message",
                        hintStyle: TextStyle(fontSize: 15, color: Colors.black54),
                        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        border: InputBorder.none,
                      ),
                      style: const TextStyle(fontSize: 15),
                      onSubmitted: (val) {
                        if (val.trim().isNotEmpty && _selectedIntercomBus != null) {
                          _sendAdminTextMessage(_selectedIntercomBus!, val.trim());
                          _adminChatInputCtrl.clear();
                        }
                      },
                      onChanged: (val) {
                        setState(() {});
                      },
                    ),
                  ),
                ),
                SizedBox(width: 10),
                InkWell(
                  onTap: () {
                    final val = _adminChatInputCtrl.text;
                    if (val.trim().isNotEmpty && _selectedIntercomBus != null) {
                      _sendAdminTextMessage(_selectedIntercomBus!, val.trim());
                      _adminChatInputCtrl.clear();
                      setState(() {});
                    } else {
                      _startRecordingVoice();
                    }
                  },
                  child: CircleAvatar(
                    backgroundColor: const Color(0xFF00A884),
                    radius: 24,
                    child: Icon(
                      _adminChatInputCtrl.text.trim().isNotEmpty ? Icons.send : Icons.mic,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }


  Widget _buildRequestsTab() {
    return _isLoadingRequests
        ? Center(child: CircularProgressIndicator())
        : _requests.isEmpty
            ? Center(child: Text(t('All pickup letter queues cleared for today.'), style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)))
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _requests.length,
                itemBuilder: (ctx, idx) {
                  final req = _requests[idx];
                  final status = req['status'] as String? ?? "pending";
                  final docName = req['documentName'] as String? ?? "Attached_Document.png";
                  final timeStr = req['timestamp'] != 0
                      ? DateTime.fromMillisecondsSinceEpoch(req['timestamp']).toString().substring(0, 16)
                      : "--";

                  return Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    margin: const EdgeInsets.only(bottom: 12),
                    color: Colors.white,
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              InkWell(
                                onTap: () => _showEnlargedStudentProfile(context, req),
                                child: Text(
                                  "${req['studentName']} - ${req['studentId'].toString().toUpperCase()}",
                                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Color(0xFF1E3A8A)),
                                ),
                              ),
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: status == "confirmed"
                                          ? const Color(0xFFDCFCE7)
                                          : (status == "rejected" ? const Color(0xFFFEE2E2) : const Color(0xFFFEF9C3)),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      status.toUpperCase(),
                                      style: TextStyle(
                                        fontSize: 8.5,
                                        fontWeight: FontWeight.bold,
                                        color: status == "confirmed"
                                            ? const Color(0xFF16A34A)
                                            : (status == "rejected" ? const Color(0xFFDC2626) : const Color(0xFFA16207)),
                                      ),
                                    ),
                                  ),
                                  SizedBox(width: 8),
                                  InkWell(
                                    onTap: () {
                                      showDialog(
                                        context: ctx,
                                        builder: (c) => AlertDialog(
                                          title: Text(t('Delete Request')),
                                          content: Text(t('Are you sure you want to completely delete this pickup request?')),
                                          actions: [
                                            TextButton(onPressed: () => Navigator.pop(c), child: Text(t('Cancel'))),
                                            TextButton(
                                              onPressed: () {
                                                Navigator.pop(c);
                                                _deleteRequest(req['studentId']);
                                              },
                                              child: Text(t('Delete'), style: TextStyle(color: Colors.red)),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                    child: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          SizedBox(height: 4),
                          Text(
                            "${req['studentDept']} • ${req['studentYear']} • Recd: $timeStr",
                            style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold),
                          ),
                          SizedBox(height: 10),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFEF3C7),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: const Color(0xFFF59E0B)),
                                ),
                                child: Builder(
                                  builder: (context) {
                                    final rawBus = (req['studentBus'] != null && req['studentBus'].toString().isNotEmpty)
                                        ? req['studentBus'].toString()
                                        : _extractBusNumber(req['savedStop']?.toString() ?? '');
                                    final rteName = _getRouteForBus(rawBus);
                                    final label = rawBus.isNotEmpty
                                        ? (rteName.isNotEmpty ? "Bus $rawBus ($rteName)" : "Bus $rawBus")
                                        : "Bus N/A";
                                    return Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.directions_bus_rounded, size: 14, color: Color(0xFFB45309)),
                                        const SizedBox(width: 4),
                                        Text(
                                          label,
                                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF78350F)),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Icon(Icons.location_on, size: 14, color: Color(0xFF2563EB)),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  "Boarding: ${req['savedStop']}",
                                  style: const TextStyle(fontSize: 11, color: Color(0xFF334155), fontWeight: FontWeight.bold),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          if (req['voiceReasonTamil'] != null && req['voiceReasonTamil'].toString().isNotEmpty) ...[
                            SizedBox(height: 12),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: InkWell(
                                onTap: () => _speakTamilReason(req['voiceReasonTamil']),
                                child: Container(
                                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: Color(0xFFEFF6FF),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: Color(0xFFBFDBFE)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.volume_up, size: 16, color: Color(0xFF2563EB)),
                                      SizedBox(width: 6),
                                      Text(t('Play Voice Reason (Tamil)'), style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A))),
                                    ],
                                  ),
                                ),
                              ),
                            )
                          ] else ...[
                            SizedBox(height: 12),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.grey.shade300),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.mic_off, size: 16, color: Colors.grey),
                                    SizedBox(width: 6),
                                    Text(t('No Voice Reason Attached'), style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey.shade600)),
                                  ],
                                ),
                              ),
                            )
                          ],
                          SizedBox(height: 12),
                          Divider(),
                          SizedBox(height: 6),
                          Row(
                            children: [
                              Icon(
                                docName.toLowerCase().endsWith(".png") || docName.toLowerCase().endsWith(".jpg")
                                    ? Icons.image
                                    : Icons.picture_as_pdf,
                                color: docName.toLowerCase().endsWith(".png") || docName.toLowerCase().endsWith(".jpg")
                                    ? Colors.orange
                                    : Colors.red,
                                size: 20,
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  docName,
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF475569)),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              TextButton(
                                onPressed: () {
                                  final docUrl = req['documentUrl'] as String?;
                                  _viewUploadedLetter(docName, docUrl ?? "");
                                },
                                child: Text(t('View Document'), style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                              ),
                            ],
                          ),
                          SizedBox(height: 10),
                          if (status == "pending") ...[
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF22C55E),
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
                                      elevation: 0,
                                    ),
                                    onPressed: () => _openApprovalVoiceDialog(req),
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        t('Confirm Request'),
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFFEF4444),
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
                                      elevation: 0,
                                    ),
                                    onPressed: () => _updateRequestStatus(req['studentId'], "rejected"),
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        t('Reject Request'),
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ] else ...[
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFEF4444),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                                elevation: 0,
                              ),
                              onPressed: () => _updateRequestStatus(req['studentId'], "pending"),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  t('Cancel'),
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              );
  }

  Widget _buildRegistryTab() {
    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          width: double.infinity,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ChoiceChip(
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      t('Drivers Registry'),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  selected: _registryViewMode == 0,
                  onSelected: (val) {
                    if (val) setState(() => _registryViewMode = 0);
                  },
                ),
                const SizedBox(width: 12),
                ChoiceChip(
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      t('Routes Registry'),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  selected: _registryViewMode == 1,
                  onSelected: (val) {
                    if (val) setState(() => _registryViewMode = 1);
                  },
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: _registryViewMode == 0 ? _buildDriversRegistrySubTab() : _buildRoutesRegistrySubTab(),
        )
      ],
    );
  }

  Widget _buildDriversRegistrySubTab() {
    final query = _driverRegistrySearchQuery.toLowerCase();
    final displayedDrivers = _drivers.where((d) {
      final rName = _getRouteDisplayName(d.route).toLowerCase();
      return d.driver.toLowerCase().contains(query) ||
             d.bus.toLowerCase().contains(query) ||
             d.route.toLowerCase().contains(query) ||
             rName.contains(query);
    }).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: TextField(
              decoration: InputDecoration(
                hintText: t('Search driver, bus, or route...'),
                prefixIcon: const Icon(Icons.search, color: Color(0xFF94A3B8)),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (val) => setState(() => _driverRegistrySearchQuery = val),
            ),
          ),
          Expanded(
            child: displayedDrivers.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.people_outline, size: 48, color: Color(0xFF94A3B8)),
                          const SizedBox(height: 12),
                          Text(
                            query.isEmpty ? "No drivers in registry" : "No matching drivers found",
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF334155)),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            query.isEmpty
                                ? "Tap the + button below to add a driver to the registry."
                                : "Try searching for a different driver name, bus number, or route.",
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: displayedDrivers.length,
                    itemBuilder: (ctx, idx) {
                final d = displayedDrivers[idx];
                return Card(
            color: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Color(0xFFEEF2FF), width: 1.5)),
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: Color(0xFFEEF2FF),
                    child: Text(t('👔'), style: TextStyle(fontSize: 20)),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(d.driver, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Color(0xFF0F172A))),
                        SizedBox(height: 2),
                        Text("Bus: ${d.bus} • Route: ${_getRouteDisplayName(d.route)}", style: const TextStyle(fontSize: 10, color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
                        Text("Category: ${d.type.toUpperCase()}", style: const TextStyle(fontSize: 9.5, color: Color(0xFF2563EB), fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.edit, size: 18),
                    onPressed: () => _openDriverEditBottomSheet(d),
                  ),
                  IconButton(
                    icon: Icon(Icons.delete_outline, size: 18, color: Colors.red),
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (diag) => AlertDialog(
                          title: Text(t('Confirm Delete')),
                          content: Text("Delete registry entry for ${d.driver}?"),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(diag), child: Text(t('Cancel'))),
                            TextButton(
                              onPressed: () async {
                                final busKey = d.bus.trim();
                                final cleanBus = busKey.replaceAll(RegExp(r'[^0-9a-zA-Z]'), '');
                                final idKey = d.id > 0 ? d.id.round().toString() : '';

                                setState(() {
                                  _drivers.removeWhere((item) =>
                                      (d.id > 0 && item.id == d.id) ||
                                      (busKey.isNotEmpty && item.bus.trim().toLowerCase() == busKey.toLowerCase()) ||
                                      (cleanBus.isNotEmpty && item.bus.replaceAll(RegExp(r'[^0-9a-zA-Z]'), '').toLowerCase() == cleanBus.toLowerCase())
                                  );
                                });
                                
                                final prefs = await SharedPreferences.getInstance();
                                prefs.setString('ptAdmin_drivers', json.encode(_drivers.map((e) => e.toJson()).toList()));

                                if (Firebase.apps.isNotEmpty) {
                                  try {
                                    if (busKey.isNotEmpty) {
                                      await FirebaseDatabase.instance.ref('drivers/$busKey').remove();
                                    }
                                    if (cleanBus.isNotEmpty && cleanBus != busKey) {
                                      await FirebaseDatabase.instance.ref('drivers/$cleanBus').remove();
                                    }
                                    if (idKey.isNotEmpty && idKey != '0') {
                                      await FirebaseDatabase.instance.ref('drivers/$idKey').remove();
                                    }
                                  } catch (e) {
                                    debugPrint("Error removing driver from Firebase: $e");
                                  }
                                }
                                _saveDrivers();
                                Navigator.pop(diag);
                                _showAppSnackBar("Driver permanently deleted.");
                              },
                              child: Text(t('Delete'), style: TextStyle(color: Colors.red)),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF2563EB),
        foregroundColor: Colors.white,
        onPressed: _openDriverAddBottomSheet,
        child: Icon(Icons.add),
      ),
    );
  }

  Widget _buildRoutesRegistrySubTab() {
    final query = _adminRouteSearchQuery.toLowerCase();
    
    final driverRoutes = _getActiveRegistryRoutes();

    final displayedRoutes = driverRoutes.where((r) {
      if (query.isEmpty) return true;
      final nameMatch = r.name.toLowerCase().contains(query);
      final stopMatch = r.stops.any((s) => s.toLowerCase().contains(query));
      return nameMatch || stopMatch;
    }).toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: TextField(
                controller: _adminRouteSearchCtrl,
                onChanged: (val) => setState(() => _adminRouteSearchQuery = val),
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  hintText: "Search by route name or bus stop...",
                  hintStyle: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                  border: InputBorder.none,
                  icon: Icon(Icons.search, size: 16, color: Color(0xFF94A3B8)),
                ),
              ),
            ),
          ),
          Expanded(
            child: displayedRoutes.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.alt_route, size: 48, color: Color(0xFF94A3B8)),
                          const SizedBox(height: 12),
                          const Text(
                            "No active routes in Driver Registry",
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF334155)),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            "Add a driver with a route in the Driver Registry, or capture stops from a driver bus to display routes here.",
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: displayedRoutes.length,
                    itemBuilder: (ctx, idx) {
                      final r = displayedRoutes[idx];
                      Color c = const Color(0xFF2563EB);
                      try {
                        c = Color(int.parse(r.color.replaceFirst('#', '0xFF')));
                      } catch (_) {}

                      // Find assigned driver in Driver Registry
                      final driver = _drivers.firstWhere(
                        (d) {
                          final cleanBus = d.bus.replaceAll(RegExp(r'[^0-9a-zA-Z]'), '').toLowerCase();
                          final cleanRoute = d.route.replaceAll(RegExp(r'[^0-9a-zA-Z]'), '').toLowerCase();
                          final cleanKey = r.key.replaceAll(RegExp(r'[^0-9a-zA-Z]'), '').toLowerCase();
                          final cleanName = r.name.replaceAll(RegExp(r'[^0-9a-zA-Z]'), '').toLowerCase();
                          return (d.route.isNotEmpty && (d.route.toLowerCase() == r.key.toLowerCase() || d.route.toLowerCase() == r.name.toLowerCase() || cleanRoute == cleanKey)) ||
                                 (cleanBus.isNotEmpty && (cleanKey.contains(cleanBus) || cleanName.contains(cleanBus) || cleanName.contains(d.bus.toLowerCase())));
                        },
                        orElse: () => DriverEntry(id: 0, bus: '', driver: '', route: '', type: ''),
                      );

                      return Card(
                        color: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: Color(0xFFEEF2FF), width: 1.5)),
                        margin: const EdgeInsets.only(bottom: 10),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text("🛣️ ${r.name}", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: c)),
                                  Text("${r.stops.length} Stops", style: const TextStyle(fontSize: 10, color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
                                ],
                              ),
                              if (driver.driver.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    const Icon(Icons.badge_outlined, size: 14, color: Color(0xFF2563EB)),
                                    const SizedBox(width: 4),
                                    Text(
                                      "Driver: ${driver.driver} • Bus: ${driver.bus}",
                                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A)),
                                    ),
                                  ],
                                ),
                              ],
                              const SizedBox(height: 6),
                              Text("Path: ${r.stops.map((s) => s.replaceAll(RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)'), '').trim()).join(' ➔ ')}", style: const TextStyle(fontSize: 10, color: Color(0xFF475569), height: 1.3, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton.icon(
                                    icon: const Icon(Icons.edit, size: 14),
                                    label: Text(t('Edit'), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                                    onPressed: () => _openRouteEditBottomSheet(r),
                                  ),
                                  TextButton.icon(
                                    icon: const Icon(Icons.delete_outline, size: 14, color: Colors.red),
                                    label: Text(t('Delete'), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.red)),
                                    onPressed: () {
                                      showDialog(
                                        context: context,
                                        builder: (diag) => AlertDialog(
                                          title: Text(t('Confirm Delete'), style: const TextStyle(fontWeight: FontWeight.bold)),
                                          content: Text("Are you sure you want to delete the ${r.name} Route?"),
                                          actions: [
                                            TextButton(onPressed: () => Navigator.pop(diag), child: Text(t('Cancel'))),
                                            TextButton(
                                              onPressed: () async {
                                                final rKey = r.key;
                                                final rName = r.name;
                                                final cleanKey = rKey.replaceAll('route_', '');
                                                setState(() {
                                                  _routes.removeWhere((item) => item.id == r.id);
                                                });
                                                // Save locally only (do NOT sync to Firebase here — the explicit .remove() calls below handle Firebase)
                                                final prefs = await SharedPreferences.getInstance();
                                                prefs.setString('ptAdmin_routes', json.encode(_routes.map((e) => e.toJson()).toList()));
                                                if (Firebase.apps.isNotEmpty) {
                                                  try {
                                                    await FirebaseDatabase.instance.ref('routes/$rKey').remove();
                                                    if (cleanKey.isNotEmpty) {
                                                      await FirebaseDatabase.instance.ref('routes/$cleanKey').remove();
                                                      await FirebaseDatabase.instance.ref('routes/route_$cleanKey').remove();
                                                    }
                                                    if (rName.isNotEmpty) {
                                                      await FirebaseDatabase.instance.ref('routes/$rName').remove();
                                                    }
                                                  } catch (e) {
                                                    debugPrint("Direct route delete error: $e");
                                                  }
                                                }
                                                Navigator.pop(diag);
                                                _showAppSnackBar("Route deleted from Firebase.");
                                              },
                                              child: Text(t('Delete'), style: const TextStyle(color: Colors.red)),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF2563EB),
        foregroundColor: Colors.white,
        onPressed: _openRouteAddBottomSheet,
        child: Icon(Icons.add),
      ),
    );
  }

  Widget _buildSpecialBusCard(Map<String, dynamic> sb) {
    List<dynamic> busesList = sb['buses'] ?? [];
    List<String> displayBuses = [];
    for (var b in busesList) {
      if (b is String) {
        displayBuses.add(b); // Legacy fallback
      } else if (b is Map) {
        String place = b['place']?.toString() ?? '';
        place = place.replaceAll(RegExp(r'^Route\s+.*?-\s*', caseSensitive: false), '');
        displayBuses.add('${b['bus']} ($place)');
      }
    }
    
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('Scheduled for ${sb['time']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
      subtitle: Text('Buses: ${displayBuses.join(", ")}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
      trailing: IconButton(
        icon: const Icon(Icons.delete, color: Colors.redAccent, size: 20),
        onPressed: () {
          FirebaseDatabase.instance.ref('special_buses/${sb['id']}').remove();
        },
      ),
    );
  }

  void _openSpecialBusAddBottomSheet() {
    TimeOfDay? selectedTime;
    List<Map<String, String>> assignedBuses = [];
    String? currentSelectedBus;
    String? currentSelectedRoute;
    
    final List<String> allBuses = _drivers.map((d) => d.bus).toSet().toList();
    if (allBuses.isEmpty) {
       allBuses.addAll(['Bus 15', 'Bus 52']);
    }
    currentSelectedBus = allBuses.isNotEmpty ? allBuses.first : null;
    currentSelectedRoute = _routes.isNotEmpty ? _routes.first.name : 'Unknown Place';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, left: 24, right: 24, top: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Add Special Bus Schedule', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 24),
                  
                  // Time Selector
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(selectedTime == null ? 'Select Time' : selectedTime!.format(ctx)),
                    trailing: const Icon(Icons.access_time),
                    onTap: () async {
                      final TimeOfDay? time = await showTimePicker(
                        context: ctx,
                        initialTime: TimeOfDay.now(),
                      );
                      if (time != null) {
                        setModalState(() => selectedTime = time);
                      }
                    },
                  ),
                  const Divider(),
                  
                  // Display Assigned Buses
                  if (assignedBuses.isNotEmpty) ...[
                    const Text('Assigned Buses:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(height: 8),
                    ...assignedBuses.map((assignment) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text('${assignment['bus']}'),
                          subtitle: Text('To: ${assignment['place']}'),
                          trailing: IconButton(
                            icon: const Icon(Icons.remove_circle, color: Colors.redAccent, size: 20),
                            onPressed: () {
                              setModalState(() {
                                assignedBuses.remove(assignment);
                              });
                            },
                          ),
                        )),
                    const Divider(),
                  ],
                  
                  // Add a new Bus -> Route pair
                  const Text('Assign a Bus to a Place:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          decoration: const InputDecoration(labelText: 'Select Bus', border: OutlineInputBorder()),
                          value: currentSelectedBus,
                          isExpanded: true,
                          items: allBuses.map((b) => DropdownMenuItem(value: b, child: Text(b, overflow: TextOverflow.ellipsis))).toList(),
                          onChanged: (val) {
                            if (val != null) setModalState(() => currentSelectedBus = val);
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          decoration: const InputDecoration(labelText: 'Select Place', border: OutlineInputBorder()),
                          value: currentSelectedRoute,
                          isExpanded: true,
                          items: _routes.isNotEmpty 
                            ? _routes.map((r) => DropdownMenuItem(value: r.name, child: Text(r.name, overflow: TextOverflow.ellipsis))).toList()
                            : [DropdownMenuItem(value: 'Unknown Place', child: Text('Unknown Place'))],
                          onChanged: (val) {
                            if (val != null) setModalState(() => currentSelectedRoute = val);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add to Schedule'),
                      onPressed: () {
                        if (currentSelectedBus != null && currentSelectedRoute != null) {
                          setModalState(() {
                            assignedBuses.add({'bus': currentSelectedBus!, 'place': currentSelectedRoute!});
                          });
                        }
                      },
                    ),
                  ),
                  
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2563EB), foregroundColor: Colors.white),
                      onPressed: () {
                        if (selectedTime == null) {
                          ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Please select a time.')));
                          return;
                        }
                        if (assignedBuses.isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Please assign at least one bus.')));
                          return;
                        }
                        
                        final ts = DateTime.now().millisecondsSinceEpoch.toString();
                        FirebaseDatabase.instance.ref('special_buses/$ts').set({
                          'time': selectedTime!.format(ctx),
                          'buses': assignedBuses,
                          'timestamp': ServerValue.timestamp,
                        });
                        
                        Navigator.pop(ctx);
                      },
                      child: const Text('Save Schedule', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            );
          },
        );
      }
    );
  }

  Widget _buildAnnouncementsTab() {
    return AnnouncementsTab(currentLang: widget.currentLang);
  }
}

class AnnouncementsTab extends StatefulWidget {
  final String currentLang;
  const AnnouncementsTab({super.key, required this.currentLang});

  @override
  State<AnnouncementsTab> createState() => _AnnouncementsTabState();
}

class _AnnouncementsTabState extends State<AnnouncementsTab> {
  String t(String key) {
    return appLang[widget.currentLang]?[key] ?? appLang['ta_added']?[key] ?? key;
  }

  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _msgCtrl = TextEditingController();
  String? _attachmentBase64;
  String? _attachmentType;
  bool _isUploading = false;

  Future<void> _pickFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'jpg', 'png', 'jpeg'],
        withData: true,
      );

      if (result != null) {
        final ext = result.files.single.extension?.toLowerCase();
        final bytes = result.files.single.bytes;
        
        if (bytes != null) {
          setState(() {
            _attachmentBase64 = base64Encode(bytes);
            _attachmentType = (ext == 'pdf') ? 'pdf' : 'image';
          });
        } else if (result.files.single.path != null) {
          // Fallback if withData fails on some platforms
          final fileBytes = await File(result.files.single.path!).readAsBytes();
          setState(() {
            _attachmentBase64 = base64Encode(fileBytes);
            _attachmentType = (ext == 'pdf') ? 'pdf' : 'image';
          });
        }
      }
    } catch (e) {
      debugPrint("File picker error: $e");
    }
  }

  Future<void> _uploadAnnouncement() async {
    if (_titleCtrl.text.isEmpty || _msgCtrl.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('Please enter title and message'))));
      return;
    }
    setState(() { _isUploading = true; });
    try {
      await FirebaseDatabase.instance.ref('announcements/active').set({
        'title': _titleCtrl.text,
        'message': _msgCtrl.text,
        'attachmentBase64': _attachmentBase64,
        'attachmentType': _attachmentType,
        'timestamp': ServerValue.timestamp,
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('Announcement Published!'))));
      _titleCtrl.clear();
      _msgCtrl.clear();
      setState(() {
        _attachmentBase64 = null;
        _attachmentType = null;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() { _isUploading = false; });
    }
  }

  Future<void> _clearAnnouncement() async {
    try {
      await FirebaseDatabase.instance.ref('announcements/active').remove();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('Active Announcement Cleared!'))));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t('Publish Announcement & Schedule'), style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A))),
          SizedBox(height: 8),
          Text(t('Upload new bus timings, routes, or general notices for all students.'), style: TextStyle(color: Colors.grey)),
          SizedBox(height: 24),
          TextField(
            controller: _titleCtrl,
            decoration: const InputDecoration(labelText: 'Title (e.g. Special Exam Schedule)', border: OutlineInputBorder()),
          ),
          SizedBox(height: 16),
          TextField(
            controller: _msgCtrl,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Message (This will scroll in the ticker)', border: OutlineInputBorder()),
          ),
          SizedBox(height: 16),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: _pickFile,
                icon: Icon(Icons.attach_file),
                label: Text(t('Attach PDF or Image')),
              ),
              if (_attachmentBase64 != null)
                Text('Attached: ${_attachmentType?.toUpperCase()}', style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
            ],
          ),
          SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2563EB), foregroundColor: Colors.white),
              onPressed: _isUploading ? null : _uploadAnnouncement,
              child: _isUploading 
                ? const CircularProgressIndicator(color: Colors.white) 
                : Text(t('Publish to Students'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          )
        ],
      ),
    );
  }
}

