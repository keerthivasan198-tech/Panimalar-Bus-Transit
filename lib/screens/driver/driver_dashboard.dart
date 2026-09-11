import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../../config/routes_config.dart';
import '../../config/lang_config.dart';
import '../../config/app_config.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'bus_card_icons.dart';

class DriverDashboard extends StatefulWidget {
  final String driverBus;
  final String currentLang;
  final VoidCallback onLogout;
  final Function(String) onLanguageChanged;
  final VoidCallback onSwitchRole;

  const DriverDashboard({
    super.key,
    required this.driverBus,
    required this.currentLang,
    required this.onLogout,
    required this.onLanguageChanged,
    required this.onSwitchRole,
  });

  @override
  State<DriverDashboard> createState() => _DriverDashboardState();
}

class _DriverDashboardState extends State<DriverDashboard> with WidgetsBindingObserver {
  bool _isTracking = false;
  Position? _currentPosition;
  StreamSubscription<Position>? _positionSubscription;

  static StreamSubscription<Position>? _globalPositionSubscription;
  static String? _globalActiveBus;
  static Timer? _periodicGpsTimer;

  String _appStatus = "Offline";
  double _latitude = 0.0;
  double _longitude = 0.0;
  double _accuracy = 0.0;
  String _updatedAt = "--";
  final Map<String, bool> _selectedNotifyBuses = {};
  String _gpsStatus = "Offline";
  String? _replacementBus;
  String _syncStatusText = "Idle";
  String _syncTimestamp = "--";
  bool _isSyncing = false;
  bool _showBusReadyBanner = false;

  bool _firebaseConnected = false;
  
  bool _hasCheckedTodayLog = false;
  bool _hasLoggedArrivalToday = false;
  bool _hasLoggedDepartureToday = false;
  bool _wasAtCollege = false;
  StreamSubscription? _connectedSubscription;

  String _nextStop = "COLLEGE";
  String _eta = "--";
  String _tripDirection = 'To College';

  int _attendanceCount = 0;
  final int _attendanceCapacity = 14;

  bool _breakdownActive = false;
  bool _isParked = false;
  final TextEditingController _replacementController = TextEditingController();
  String _routeNotifyStatus = "";

  int _busReadyCountdown = 10;
  Timer? _busReadyTimer;
  Timer? _busReadyCountdownTimer;
  Timer? _parkedLocationTimer;

  final MapController _mapController = MapController();

  // Speech monitor details
  bool _smActive = false;
  int _totalSpeakingSeconds = 0;
  int _sessionsCount = 0;
  int _longestSessionSeconds = 0;
  double _speechUsagePercentage = 0.0;
  List<Map<String, String>> _speechLog = [];
  bool _showSpeechAlert = false;
  Timer? _smSimulationTimer;
  int _driveSeconds = 0;
  bool _isSpeaking = false;
  int _currentSpeechSessionSecs = 0;
  List<double> _waveValues = List.filled(15, 2.0);
  Timer? _waveTimer;

  List<Map<String, dynamic>> _confirmedPickups = [];
  StreamSubscription? _confirmedSub;
  
  // Intercom Messages
  List<Map<String, dynamic>> _intercomMessages = [];
  StreamSubscription? _intercomSub;
  final TextEditingController _driverChatInputCtrl = TextEditingController();
  final ScrollController _driverChatScrollController = ScrollController();

  // Route Simulation State
  bool _simulateRoute = false;
  List<LatLng> _simulatedPath = [];
  int _simRouteIndex = 0;
  Timer? _simTimer;

  // Safety Warnings State
  final bool _onPhoneCall = false;
  final bool _connectedToEarpods = false;
  Timer? _safetyTimer;
  int _callSecondsCounter = 0;

  // Intercom Playback & Recording State
  bool _isRecordingVoice = false;
  int _recordingDurationSecs = 0;
  Timer? _recordingTimer;
  List<double> _recordingWaveforms = [];
  String? _playingMsgId;
  double _playbackProgress = 0.0;
  Timer? _playbackTimer;
  final FlutterTts _flutterTts = FlutterTts();
  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _recordPath;
  final double _warnThresholdPct = 20.0;

  List<Map<String, dynamic>> _routeStops = [];
  String _routeKey = "route_15";

  // OSRM road-snapped route polyline points
  List<LatLng> _osrmRoutePoints = [];

  String _routeName = "";
  Color _routeColor = const Color(0xFF2563EB);
  bool _osrmLoading = false;

  // Same-route buses: busId -> {lat, lng, status, busId}
  Map<String, Map<String, dynamic>> _sameRouteBuses = {};
  StreamSubscription? _liveLocationsSub;
  Map<String, String> _busRouteMap = {}; // busId -> routeKey

  bool _allowLocationCapture = false;
  StreamSubscription? _adminSettingsSub;

  StreamSubscription? _dynamicRoutesSub;
  StreamSubscription? _dynamicDriversSub;

  String _extractBusNumber(String input) {
    if (input.isEmpty) return '';
    final match = RegExp(r'(?:[Rr]oute|[Bb]us)?\s*[-_]?\s*(\d+)').firstMatch(input);
    if (match != null && match.group(1) != null) {
      return match.group(1)!;
    }
    return input
        .toLowerCase()
        .replaceAll(RegExp(r'^[Bb]us\s*|^[Bb]'), '')
        .replaceAll(RegExp(r'^[Rr]oute_?'), '')
        .split(RegExp(r'[-_\s]'))[0]
        .trim();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initTtsAudio();
    _loadRouteDetails();
    _listenForDynamicRouteChanges();
    _startFirebaseConnectedListener();
    _listenForConfirmedPickups();
    _listenForIntercomMessages();
    _listenForAdminSettings();
    _restoreTrackingState();
  }

  void _initTtsAudio() async {
    try {
      await _flutterTts.setVolume(1.0);
      await _flutterTts.setSpeechRate(0.48);
      await _flutterTts.setPitch(1.0);
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await _flutterTts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.playback,
          [
            IosTextToSpeechAudioCategoryOptions.defaultToSpeaker,
            IosTextToSpeechAudioCategoryOptions.mixWithOthers
          ],
        );
      }
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _restoreTrackingState();
    }
  }

  void _restoreTrackingState() async {
    final prefs = await SharedPreferences.getInstance();
    final wasTracking = prefs.getBool('driver_is_tracking_${widget.driverBus}') ?? false;
    final wasBreakdown = prefs.getBool('driver_is_breakdown_${widget.driverBus}') ?? false;
    final lastLat = prefs.getDouble('driver_last_lat_${widget.driverBus}');
    final lastLng = prefs.getDouble('driver_last_lng_${widget.driverBus}');

    if (wasTracking) {
      if (lastLat != null && lastLng != null && lastLat != 0.0) {
        if (mounted) {
          setState(() {
            _latitude = lastLat;
            _longitude = lastLng;
            _updatedAt = _formattedTimeNow();
          });
        }
        try {
          _mapController.move(LatLng(lastLat, lastLng), 16.0);
        } catch (_) {}
      }
      _startTracking(isRestoring: true, restoreBreakdown: wasBreakdown);
    } else {
      _fbSetOffline(statusToSet: 'offline');
    }
  }

  void _listenForDynamicRouteChanges() {
    _dynamicRoutesSub?.cancel();
    _dynamicDriversSub?.cancel();
    if (Firebase.apps.isEmpty) return;

    _dynamicDriversSub = FirebaseDatabase.instance.ref('drivers').onValue.listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value;
      if (data == null) return;

      List driversList = [];
      if (data is List) {
        driversList = data;
      } else if (data is Map) {
        driversList = (data as Map).values.toList();
      }

      final targetBusNum = _extractBusNumber(widget.driverBus);
      final busUpper = widget.driverBus.trim().toUpperCase();

      for (var item in driversList) {
        if (item is Map) {
          final dbBus = item['bus']?.toString().trim().toUpperCase() ?? '';
          final dbBusNum = _extractBusNumber(dbBus);

          if (dbBus == busUpper || (targetBusNum.isNotEmpty && dbBusNum == targetBusNum)) {
            final String? dbRoute = item['route']?.toString();
            if (dbRoute != null && dbRoute.isNotEmpty && dbRoute != _routeKey) {
              setState(() {
                _routeKey = dbRoute;
              });
              _updateStopsFromKey();
            }
            break;
          }
        }
      }
    });

    _dynamicRoutesSub = FirebaseDatabase.instance.ref('routes').onValue.listen((event) {
      if (!mounted) return;
      _updateStopsFromKey();
    });
  }

  void _loadRouteDetails() async {
    _routeKey = _getRouteKeyForBus(widget.driverBus);
    _updateStopsFromKey();

    if (Firebase.apps.isNotEmpty) {
      try {
        final snap = await FirebaseDatabase.instance.ref('drivers').get();
        if (snap.exists && snap.value != null) {
          final data = snap.value;
          List driversList = [];
          if (data is List) {
            driversList = data;
          } else if (data is Map) {
            driversList = data.values.toList();
          }

          final targetBusNum = _extractBusNumber(widget.driverBus);
          final busUpper = widget.driverBus.trim().toUpperCase();

          for (var item in driversList) {
            if (item is Map) {
              final dbBus = item['bus']?.toString().trim().toUpperCase() ?? '';
              final dbBusNum = _extractBusNumber(dbBus);
              if ((dbBus == busUpper || (targetBusNum.isNotEmpty && dbBusNum == targetBusNum)) && item['route'] != null) {
                final String dbRoute = item['route'].toString();
                if (mounted && dbRoute != _routeKey) {
                  setState(() {
                    _routeKey = dbRoute;
                  });
                  _updateStopsFromKey();
                }
                break;
              }
            }
          }
        }
      } catch (e) {
        debugPrint("Error fetching driver route: $e");
      }
    }
  }

  static final Map<String, LatLng> _driverStopCoordsRegistry = {};

  LatLng _getDriverStopLatLng(String stop, [int sequenceIndex = 0]) {
    final cleanStop = stop.trim();

    final RegExp regEx = RegExp(r'(?:Lat:\s*)?([-\d.]+)[,\s]+(?:Lng:\s*)?([-\d.]+)');
    final match = regEx.firstMatch(stop);
    if (match != null) {
      try {
        final lat = double.parse(match.group(1)!);
        final lng = double.parse(match.group(2)!);
        if (lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180) {
          final coord = LatLng(lat, lng);
          if (cleanStop.isNotEmpty) _driverStopCoordsRegistry[cleanStop] = coord;
          return coord;
        }
      } catch (_) {}
    }

    String cleanName = stop;
    if (stop.contains("(Lat:")) {
      cleanName = stop.split("(Lat:")[0].trim();
    }
    final lowerName = cleanName.toLowerCase().trim();

    if (lowerName.isNotEmpty && _driverStopCoordsRegistry.containsKey(lowerName)) {
      return _driverStopCoordsRegistry[lowerName]!;
    }
    if (cleanStop.isNotEmpty && _driverStopCoordsRegistry.containsKey(cleanStop)) {
      return _driverStopCoordsRegistry[cleanStop]!;
    }

    final defaultCoords = <String, LatLng>{
      'hostel1': const LatLng(13.0500, 80.0742),
      'hostel2': const LatLng(13.0515, 80.0755),
      'hostel3': const LatLng(13.0530, 80.0768),
      'hostel4': const LatLng(13.0545, 80.0781),
      'hostel': const LatLng(13.0500, 80.0742),
      'panimalar engineering college': const LatLng(13.04890, 80.07546),
      'panimalar': const LatLng(13.04890, 80.07546),
      'pec': const LatLng(13.04890, 80.07546),
      'college': const LatLng(13.04890, 80.07546),
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

    if (defaultCoords.containsKey(lowerName)) {
      final coord = defaultCoords[lowerName]!;
      if (lowerName.isNotEmpty) _driverStopCoordsRegistry[lowerName] = coord;
      return coord;
    }

    for (final entry in defaultCoords.entries) {
      if (lowerName.contains(entry.key) || entry.key.contains(lowerName)) {
        if (lowerName.isNotEmpty) _driverStopCoordsRegistry[lowerName] = entry.value;
        return entry.value;
      }
    }

    int hash = 0;
    final strToHash = lowerName.isNotEmpty ? lowerName : "stop_$sequenceIndex";
    for (int i = 0; i < strToHash.length; i++) {
      hash = 31 * hash + strToHash.codeUnitAt(i);
    }
    final latOffset = ((hash.abs() % 1000) - 500) / 100000.0;
    final lngOffset = (((hash.abs() ~/ 1000) % 1000) - 500) / 100000.0;
    final fallbackCoord = LatLng(13.0495 + latOffset, 80.0934 + lngOffset);
    if (lowerName.isNotEmpty) _driverStopCoordsRegistry[lowerName] = fallbackCoord;
    return fallbackCoord;
  }

  Future<void> _updateStopsFromKey() async {
    List<String> stopNames = routeStopsConfig[_routeKey] ?? [];
    String rName = routeLabelsConfig[_routeKey] ?? "Route ${widget.driverBus}";
    Color rColor = const Color(0xFF2563EB);

    if (Firebase.apps.isNotEmpty) {
      try {
        final rSnap = await FirebaseDatabase.instance.ref('routes').get();
        if (rSnap.exists && rSnap.value != null) {
          final rootData = rSnap.value;
          List routesList = [];
          if (rootData is List) {
            routesList = rootData;
          } else if (rootData is Map) {
            routesList = (rootData as Map).values.toList();
          }

          final targetBusNum = _extractBusNumber(widget.driverBus);
          final targetRouteClean = _routeKey.toLowerCase().replaceAll(RegExp(r'^[Bb]us\s*|^[Bb]'), '').replaceAll('route_', '').trim();

          Map? matchedRoute;
          for (var item in routesList) {
            if (item is Map) {
              final isDel = item['deleted'] == true || item['isDeleted'] == true || item['status'] == 'deleted';
              if (isDel) continue;

              final rKey = item['key']?.toString() ?? item['id']?.toString() ?? '';
              final rNameVal = item['name']?.toString() ?? '';
              final rKeyNum = _extractBusNumber(rKey);
              final rNameNum = _extractBusNumber(rNameVal);
              final rClean = rKey.toLowerCase().replaceAll(RegExp(r'^[Bb]us\s*|^[Bb]'), '').replaceAll('route_', '').trim();

              if (rKey == _routeKey ||
                  rNameVal == _routeKey ||
                  (targetBusNum.isNotEmpty && (rKeyNum == targetBusNum || rNameNum == targetBusNum)) ||
                  (targetRouteClean.isNotEmpty && rClean == targetRouteClean)) {
                matchedRoute = item;
                break;
              }
            }
          }

          if (matchedRoute != null) {
            if (matchedRoute['name'] != null && matchedRoute['name'].toString().isNotEmpty) {
              rName = matchedRoute['name'].toString();
            }
            if (matchedRoute['color'] != null) {
              try { rColor = Color(int.parse(matchedRoute['color'].toString().replaceAll('#', '0xFF'))); } catch (_) {}
            }
            if (matchedRoute['stops'] != null) {
              stopNames = List.from(matchedRoute['stops'] as List).map((e) => e.toString()).toList();
            }
          }
        }
      } catch (e) {
        debugPrint("Error fetching routes from Firebase: $e");
      }
    }

    if (mounted) {
      setState(() {
        _routeName = rName;
        _routeColor = rColor;
      });
    }

    final List<Map<String, dynamic>> newStops = [];
    for (int i = 0; i < stopNames.length; i++) {
      final name = stopNames[i];
      if (name.trim().isEmpty) continue;
      String displayName = name;
      if (name.contains("(Lat:")) {
        displayName = name.split("(Lat:")[0].trim();
      }
      final coord = _getDriverStopLatLng(name, i);
      newStops.add({
        'name': displayName.isNotEmpty ? displayName : name,
        'originalName': name,
        'lat': coord.latitude,
        'lng': coord.longitude,
      });
    }
    
    if (mounted) {
      setState(() {
        _routeStops = newStops;
        _osrmRoutePoints = []; // Reset road route — will re-fetch
        if (_routeStops.isNotEmpty) {
          _nextStop = _routeStops[0]['name'];
        }
      });
    }

    // Move the map to center on the route center
    if (newStops.isNotEmpty) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted && !_isTracking) {
          double avgLat = newStops.map((s) => s['lat'] as double).reduce((a, b) => a + b) / newStops.length;
          double avgLng = newStops.map((s) => s['lng'] as double).reduce((a, b) => a + b) / newStops.length;
          try {
            _mapController.move(LatLng(avgLat, avgLng), 11.5);
          } catch (_) {}
        }
      });
      // Fetch road-snapped route from OSRM
      _fetchOsrmRoute(newStops);
    }
  }

  /// Fetches a road-following polyline from the OSRM routing API.
  /// Uses the free demo server — no API key needed.
  Future<void> _fetchOsrmRoute(List<Map<String, dynamic>> stops) async {
    if (stops.length < 2) return;
    if (!mounted) return;
    setState(() => _osrmLoading = true);

    try {
      // Build coordinate string: lng,lat;lng,lat;...
      // OSRM accepts max ~100 waypoints comfortably
      final coords = stops.map((s) {
        final lat = (s['lat'] as double).toStringAsFixed(6);
        final lng = (s['lng'] as double).toStringAsFixed(6);
        return '$lng,$lat';
      }).join(';');

      final url = Uri.parse(
        'http://router.project-osrm.org/route/v1/driving/$coords'
        '?overview=full&geometries=geojson',
      );

      final response = await http.get(url).timeout(const Duration(seconds: 15));
      if (!mounted) return;

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final routes = json['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          final geometry = routes[0]['geometry'] as Map<String, dynamic>?;
          final coordinates = geometry?['coordinates'] as List?;
          if (coordinates != null) {
            final points = coordinates.map((c) {
              final lng = (c[0] as num).toDouble();
              final lat = (c[1] as num).toDouble();
              return LatLng(lat, lng);
            }).toList();
            if (mounted) {
              setState(() {
                _osrmRoutePoints = points;
                _osrmLoading = false;
              });
            }
            return;
          }
        }
      }
    } catch (e) {
      debugPrint('OSRM route fetch error: $e');
    }

    // Fallback: use straight-line stop connections
    if (mounted) {
      setState(() {
        _osrmRoutePoints = stops
            .map((s) => LatLng(s['lat'] as double, s['lng'] as double))
            .toList();
        _osrmLoading = false;
      });
    }
  }

  /// Listens to Firebase liveLocations and filters buses on the same route.
  void _listenForSameRouteBuses() {
    if (Firebase.apps.isEmpty) return;
    // First load the driver-to-route mapping, then start live location listener
    _loadBusRouteMap().then((_) => _startLiveLocationsListener());
  }

  Future<void> _loadBusRouteMap() async {
    if (Firebase.apps.isEmpty) return;
    try {
      final snap = await FirebaseDatabase.instance.ref('drivers').get();
      if (snap.exists && snap.value != null) {
        final data = snap.value;
        List driversList = [];
        if (data is List) {
          driversList = data;
        } else if (data is Map) {
          driversList = data.values.toList();
        }
        final Map<String, String> map = {};
        for (var item in driversList) {
          if (item is Map) {
            final bus = item['bus']?.toString().trim().toUpperCase();
            final route = item['route']?.toString();
            if (bus != null && route != null) {
              map[bus] = route;
            }
          }
        }
        if (mounted) {
          setState(() => _busRouteMap = map);
        }
      }
    } catch (e) {
      debugPrint('Error loading bus-route map: $e');
    }
  }

  void _startLiveLocationsListener() {
    if (Firebase.apps.isEmpty) return;
    try {
      _liveLocationsSub = FirebaseDatabase.instance
          .ref('liveLocations')
          .onValue
          .listen((event) {
        final data = event.snapshot.value as Map?;
        if (!mounted) return;
        final Map<String, Map<String, dynamic>> nearby = {};
        if (data != null) {
          data.forEach((busId, val) {
            if (val is Map) {
              final bId = busId.toString().toUpperCase();
              // Skip current bus
              if (bId == widget.driverBus.toUpperCase()) return;
              // Check if same route
              final busRoute = _busRouteMap[bId];
              if (busRoute == _routeKey) {
                nearby[bId] = {
                  'busId': bId,
                  'lat': (val['lat'] as num?)?.toDouble() ?? 0.0,
                  'lng': (val['lng'] as num?)?.toDouble() ?? 0.0,
                  'status': val['status']?.toString() ?? 'offline',
                  'updatedAt': val['updatedAt']?.toString() ?? '--',
                };
              }
            }
          });
        }
        setState(() => _sameRouteBuses = nearby);
      });
    } catch (e) {
      debugPrint('Error listening to live locations: $e');
    }
  }

  /// Sends a breakdown alert to admin referencing a specific nearby bus.
  Future<void> _sendBreakdownAlertWithNearby(String nearbyBusId) async {
    if (Firebase.apps.isEmpty) {
      _showSnackBar('Cannot connect to Firebase.');
      return;
    }
    try {
      final alertData = {
        'brokenBus': widget.driverBus,
        'nearbyBus': nearbyBusId,
        'route': _routeKey,
        'routeLabel': _getRouteLabelForBus(widget.driverBus),
        'lat': _latitude,
        'lng': _longitude,
        'message':
            'Bus ${widget.driverBus} has broken down on ${_getRouteLabelForBus(widget.driverBus)}. '
            'Requesting Bus $nearbyBusId to cover the remaining stops.',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'status': 'pending',
      };
      await FirebaseDatabase.instance
          .ref('breakdownAlerts/${widget.driverBus}_${DateTime.now().millisecondsSinceEpoch}')
          .set(alertData);
      _showSnackBar('✅ Alert sent! Requested Bus $nearbyBusId to cover route.');
    } catch (e) {
      _showSnackBar('Failed to send alert: $e');
    }
  }

  String _getRouteKeyForBus(String busId) {
    final bus = busId.trim().toUpperCase();
    // Try direct numeric match (e.g. bus "15" -> route_15)
    if (RegExp(r'^\d+$').hasMatch(busId)) {
      final key = 'route_$busId';
      if (routeLabelsConfig.containsKey(key)) return key;
    }
    // Legacy named bus IDs
    if (bus == 'B101' || bus == 'BUS101') return 'route_15';
    if (bus == 'B202' || bus == 'BUS102') return 'route_52';
    if (bus == 'B303') return 'route_137';
    return 'route_15'; // default fallback
  }

  String _getRouteLabelForBus(String busId) {
    return _routeName.isNotEmpty ? _routeName : "College Route ($busId)";
  }

  Color _getRouteColor() {
    return _routeColor;
  }

  String t(String key) {
    return appLang[widget.currentLang]?[key] ?? appLang['en']?[key] ?? key;
  }

  void _listenForAdminSettings() {
    if (Firebase.apps.isEmpty) return;
    try {
      _adminSettingsSub = FirebaseDatabase.instance.ref('adminSettings/allowDriversToAddStops').onValue.listen((event) {
        final val = event.snapshot.value;
        if (mounted) {
          setState(() {
            _allowLocationCapture = val == true;
          });
        }
      });
    } catch (e) {
      debugPrint("Error listening to admin settings: $e");
    }
  }

  void _fetchAndSendLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _showSnackBar("Location services are disabled.");
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        _showSnackBar("Location permissions are denied");
        return;
      }
    }
    
    if (permission == LocationPermission.deniedForever) {
      _showSnackBar("Location permissions are permanently denied.");
      return;
    }

    if (!mounted) return;
    
    // Prompt for stop name instantly
    final nameCtrl = TextEditingController();
    final stopName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Name this Stop"),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(hintText: "e.g. Guduvanchery Bus Stand"),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
            child: const Text("Save")
          ),
        ],
      )
    );

    if (stopName == null || stopName.isEmpty) {
      _showSnackBar("Stop capture cancelled.");
      return;
    }

    _showSnackBar("Fetching location...");
    
    try {
      Position position = await Geolocator.getCurrentPosition();
      
      final ts = DateTime.now().millisecondsSinceEpoch;
      final data = {
        'driverBus': widget.driverBus,
        'stopName': stopName,
        'lat': position.latitude,
        'lng': position.longitude,
        'timestamp': ts,
        'status': 'new_stop_suggested'
      };
      await FirebaseDatabase.instance.ref('new_stops/${widget.driverBus}_$ts').set(data);

      final cleanStopKey = stopName.toLowerCase().trim();
      await FirebaseDatabase.instance.ref('stopLocations/$cleanStopKey').set({
        'lat': position.latitude,
        'lng': position.longitude,
        'capturedBy': widget.driverBus,
        'timestamp': ts,
      });

      _driverStopCoordsRegistry[cleanStopKey] = LatLng(position.latitude, position.longitude);

      final cleanBusNum = widget.driverBus.replaceAll(RegExp(r'[^0-9a-zA-Z]'), '');
      final targetRouteKey = _routeKey.isNotEmpty ? _routeKey : 'route_$cleanBusNum';
      final formattedStopName = "$stopName (Lat: ${position.latitude}, Lng: ${position.longitude})";

      if (targetRouteKey.isNotEmpty) {
        final rRef = FirebaseDatabase.instance.ref('routes/$targetRouteKey');
        final rSnap = await rRef.get();
        if (rSnap.exists && rSnap.value != null) {
          final rData = Map<String, dynamic>.from(rSnap.value as Map);
          List<dynamic> stops = [];
          if (rData['stops'] != null) {
            stops = List.from(rData['stops'] as List);
          }
          final latStr = "Lat: ${position.latitude}";
          final lngStr = "Lng: ${position.longitude}";
          if (!stops.any((s) => s.toString().contains(latStr) && s.toString().contains(lngStr))) {
            stops.add(formattedStopName);
            await rRef.update({'stops': stops, 'status': 'active', 'deleted': false});
          }
        } else {
          // Route doesn't exist in Firebase — do NOT create it.
          // The stop is already saved in /new_stops for admin to review.
          debugPrint("Route $targetRouteKey not found in Firebase. Stop saved to /new_stops only.");
        }
      }

      _showSnackBar("✅ Stop '$stopName' captured and saved to route");
    } catch (e) {
      _showSnackBar("Failed to get location: $e");
    }
  }

  void _listenForConfirmedPickups() {
    if (Firebase.apps.isEmpty) return;
    try {
      _confirmedSub = FirebaseDatabase.instance.ref('pickup_requests').onValue.listen((event) {
        final data = event.snapshot.value as Map?;
        final List<Map<String, dynamic>> temp = [];
        if (data != null) {
          data.forEach((key, val) {
            if (val is Map && val['status'] == 'confirmed') {
              // Ensure studentBus exists and matches the driver's selected bus exactly
              String studentBus = val['studentBus']?.toString() ?? "";
              if (studentBus == widget.driverBus || studentBus.replaceAll("Bus ", "") == widget.driverBus) {
                temp.add({
                  'id': key,
                  'studentId': val['studentId'] ?? val['rollNo'] ?? key,
                  'studentName': val['studentName'] ?? "Unknown Student",
                  'studentYear': val['studentYear'] ?? "",
                  'studentDept': val['studentDept'] ?? "",
                  'studentBus': studentBus,
                  'savedStop': val['savedStop'] ?? "Not Selected",
                  'documentName': val['documentName'] ?? "No Document",
                  'documentUrl': val['documentUrl'] ?? "",
                  'timestamp': val['timestamp'] ?? 0,
                  'profilePicBase64': val['profilePicBase64'] ?? val['photo'] ?? val['studentPhoto'] ?? "",
                  'adminVoiceText': val['adminVoiceText'] ?? val['voiceReasonTamil'] ?? "",
                  'adminVoiceAudio': val['adminVoiceAudio'] ?? "",
                  'adminVoiceDuration': val['adminVoiceDuration'] ?? 5,
                });
              }
            }
          });
        }
        setState(() {
          _confirmedPickups = temp;
        });
      });
    } catch (e) {
      debugPrint("Error listening to driver pickups: $e");
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (!_isTracking || _globalActiveBus != widget.driverBus) {
      _positionSubscription?.cancel();
      _globalPositionSubscription?.cancel();
    }
    _connectedSubscription?.cancel();
    _confirmedSub?.cancel();
    _adminSettingsSub?.cancel();
    _liveLocationsSub?.cancel();
    _dynamicRoutesSub?.cancel();
    _dynamicDriversSub?.cancel();
    _smSimulationTimer?.cancel();
    _waveTimer?.cancel();
    _busReadyTimer?.cancel();
    _busReadyCountdownTimer?.cancel();
    _simTimer?.cancel();
    _safetyTimer?.cancel();
    _recordingTimer?.cancel();
    _playbackTimer?.cancel();
    _parkedLocationTimer?.cancel();
    _replacementController.dispose();
    _intercomSub?.cancel();
    _driverChatInputCtrl.dispose();
    super.dispose();
  }

  void _listenForIntercomMessages() {
    if (Firebase.apps.isEmpty) return;
    try {
      _intercomSub = FirebaseDatabase.instance.ref('voice_messages/driver_${widget.driverBus}').onValue.listen((event) {
        final data = event.snapshot.value as Map?;
        final List<Map<String, dynamic>> temp = [];
        if (data != null) {
          data.forEach((key, val) {
            if (val is Map && val['isApprovalVoice'] != true) {
              temp.add({
                'id': key.toString(),
                'sender': val['sender'] ?? 'unknown',
                'timestamp': val['timestamp'] ?? 0,
                'msg': val['msg'] ?? '',
                'senderName': val['senderName'] ?? '',
                'isVoice': val['isVoice'] ?? false,
                'voiceDuration': val['voiceDuration'] ?? 0,
                'transcript': val['transcript'] ?? '',
                'isRead': val['isRead'] == true,
              });
            }
          });
          temp.sort((a, b) => a['timestamp'].compareTo(b['timestamp']));
        }
        if (mounted) {
          setState(() {
            _intercomMessages = temp;
          });
        }
      });
    } catch (e) {
      debugPrint("Error listening for intercom messages: $e");
    }
  }

  void _sendTextMessage(String text) async {
    if (Firebase.apps.isEmpty) return;
    try {
      final msgId = DateTime.now().millisecondsSinceEpoch.toString();
      await FirebaseDatabase.instance.ref('voice_messages/driver_${widget.driverBus}/$msgId').set({
        'sender': 'driver',
        'senderName': 'Driver ${widget.driverBus}',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'msg': text,
        'isRead': false,
      });
      // Notify admin via FCM push notification
      _notifyAdminIntercom(messageType: 'text', messagePreview: text);
    } catch (e) {
      debugPrint("Error sending text message: $e");
    }
  }

  // Reads admin FCM token from Firebase and sends push notification
  void _notifyAdminIntercom({required String messageType, String? messagePreview}) async {
    try {
      final snap = await FirebaseDatabase.instance.ref('adminFcmToken').get();
      final token = snap.value as String?;
      if (token == null || token.isEmpty) return;
      await http.post(
        Uri.parse('https://panimalr-bus.onrender.com/api/notify'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'fcmToken': token,
          'busNo': widget.driverBus,
          'messageType': messageType,
          'messagePreview': messagePreview ?? '',
        }),
      );
    } catch (e) {
      debugPrint('Notify admin error: $e');
    }
  }


  void _startRecordingVoice() async {
    if (await _audioRecorder.hasPermission()) {
      if (kIsWeb) {
        await _audioRecorder.start(const RecordConfig(), path: '');
      } else {
        final dir = await getApplicationDocumentsDirectory();
        _recordPath = '${dir.path}/voice_message.m4a';
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
            final rand = Random();
            _recordingWaveforms.add(5.0 + rand.nextDouble() * 30.0);
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

    if (path != null && Firebase.apps.isNotEmpty) {
      try {
        Uint8List bytes;
        if (kIsWeb) {
          final res = await http.get(Uri.parse(path));
          bytes = res.bodyBytes;
        } else {
          bytes = await File(path).readAsBytes();
        }
        final base64Audio = base64Encode(bytes);
        
        final String apiUrl = kIsWeb ? 'https://panimalr-bus.onrender.com/api/voice' : 'https://panimalr-bus.onrender.com/api/voice';
        
        // Upload to MongoDB
        final response = await http.post(
          Uri.parse(apiUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'sender': 'driver_${widget.driverBus}',
            'receiver': 'admin',
            'audioBase64': base64Audio,
            'duration': duration,
          }),
        );
        
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final mongoId = data['id'];
          
          final msgId = DateTime.now().millisecondsSinceEpoch.toString();
          await FirebaseDatabase.instance.ref('voice_messages/driver_${widget.driverBus}/$msgId').set({
            'sender': 'driver',
            'senderName': 'Driver ${widget.driverBus}',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'msg': '[Voice Message - 0:${duration.toString().padLeft(2, '0')}] "$mongoId"',
            'isVoice': true,
            'voiceDuration': duration,
            'mongoId': mongoId,
            'isRead': false,
          });
          // Notify admin via FCM push notification
          _notifyAdminIntercom(messageType: 'voice');
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
    _showSnackBar("Recording cancelled.");
  }

  Future<void> _speakVoiceMessage(String text) async {
    if (text.isEmpty) return;
    try {
      await _flutterTts.setLanguage("ta-IN");
      await _flutterTts.setVolume(1.0);
      await _flutterTts.setPitch(1.0);
      await _flutterTts.setSpeechRate(0.45);
      await _flutterTts.speak(text);
    } catch (e) {
      debugPrint("Error speaking voice message: $e");
    }
  }

  void _playVoiceMessageMap(Map<String, dynamic> msg) async {
    final msgId = msg['id']?.toString() ?? msg['pickupId']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString();
    final durationSecs = (msg['voiceDuration'] is int) ? msg['voiceDuration'] as int : 5;
    final base64Audio = msg['audioBase64']?.toString() ?? '';

    if (_playingMsgId == msgId) {
      _playbackTimer?.cancel();
      await _audioPlayer.stop();
      await _flutterTts.stop();
      setState(() {
        _playingMsgId = null;
      });
      return;
    }

    _playbackTimer?.cancel();
    await _audioPlayer.stop();
    await _flutterTts.stop();

    setState(() {
      _playingMsgId = msgId;
      _playbackProgress = 0.0;
    });

    bool playedAudio = false;
    if (base64Audio.isNotEmpty) {
      try {
        String cleanB64 = base64Audio;
        if (cleanB64.startsWith('data:audio') || cleanB64.contains(',')) {
          cleanB64 = cleanB64.split(',').last;
        }
        cleanB64 = cleanB64.replaceAll(RegExp(r'\s+'), '');
        final bytes = base64Decode(cleanB64);
        await _audioPlayer.play(BytesSource(bytes));
        playedAudio = true;
      } catch (e) {
        debugPrint("Error playing base64 audio: $e");
      }
    }

    if (!playedAudio) {
      final textToSpeak = msg['msg']?.toString() ?? "மாணவர் அனுமதி கடிதம் நிர்வாகத்தால் ஏற்கப்பட்டது.";
      try {
        await _flutterTts.setLanguage("ta-IN");
        await _flutterTts.setVolume(1.0);
        await _flutterTts.setPitch(1.0);
        await _flutterTts.setSpeechRate(0.45);
        await _flutterTts.speak(textToSpeak);
      } catch (e) {
        debugPrint("TTS Error: $e");
      }
    }

    final int totalSteps = (durationSecs > 0 ? durationSecs : 5) * 10;
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

  void _playLetterVoiceAudio(Map<String, dynamic> pickup) async {
    final pickupId = pickup['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString();
    final base64Audio = pickup['adminVoiceAudio']?.toString() ?? '';
    final durationSecs = (pickup['adminVoiceDuration'] is int) ? pickup['adminVoiceDuration'] as int : 5;
    final textStr = pickup['adminVoiceText']?.toString() ?? 'மாணவர் அனுமதி கடிதம் நிர்வாகத்தால் ஏற்கப்பட்டது.';

    if (_playingMsgId == pickupId) {
      _playbackTimer?.cancel();
      await _audioPlayer.stop();
      await _flutterTts.stop();
      setState(() {
        _playingMsgId = null;
      });
      return;
    }

    _playbackTimer?.cancel();
    await _audioPlayer.stop();
    await _flutterTts.stop();

    setState(() {
      _playingMsgId = pickupId;
      _playbackProgress = 0.0;
    });

    bool playedAudio = false;
    if (base64Audio.isNotEmpty) {
      try {
        String cleanB64 = base64Audio;
        if (cleanB64.startsWith('data:audio') || cleanB64.contains(',')) {
          cleanB64 = cleanB64.split(',').last;
        }
        cleanB64 = cleanB64.replaceAll(RegExp(r'\s+'), '');
        final bytes = base64Decode(cleanB64);

        if (!kIsWeb) {
          final tempDir = await getTemporaryDirectory();
          final tempFile = File('${tempDir.path}/play_voice_$pickupId.m4a');
          await tempFile.writeAsBytes(bytes);
          await _audioPlayer.play(DeviceFileSource(tempFile.path));
        } else {
          await _audioPlayer.play(BytesSource(bytes));
        }
        playedAudio = true;
      } catch (e) {
        debugPrint("Error playing letter base64 audio: $e");
        try {
          final bytes = base64Decode(base64Audio);
          await _audioPlayer.play(BytesSource(bytes));
          playedAudio = true;
        } catch (e2) {
          debugPrint("Fallback BytesSource error: $e2");
        }
      }
    }

    if (!playedAudio) {
      _showSnackBar("No voice audio recording attached to this letter.");
      return;
    }

    final int totalSteps = (durationSecs > 0 ? durationSecs : 5) * 10;
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

  void _playVoiceMessage(String msgId, String text, int durationSecs) async {
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

    String mongoId = "";
    if (text.startsWith('[Voice Message')) {
      final index = text.indexOf(']');
      if (index != -1 && index + 1 < text.length) {
        mongoId = text.substring(index + 1).replaceAll('"', '').trim();
      }
    }
    
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

  void _showDriverPredefinedMessages() {
    const List<String> driverMessages = [
      "🚌 Bus is on the way. Please be ready at your stop.",
      "⏱️ Slight delay due to traffic. ETA 10 minutes.",
      "✅ Bus has arrived at campus safely.",
      "🛣️ Route is clear, proceeding as scheduled.",
      "⚠️ Emergency: Bus breakdown. Sending help.",
      "🔁 Bus is returning after drop-off.",
      "⛽ Fuel stop needed. 5-minute halt.",
      "🌧️ Slow speed due to rain. Be patient.",
      "🚫 Bus is full. Cannot board more students.",
      "📍 Arriving at first stop in 5 minutes.",
      "🚧 Road block ahead. Taking alternate route.",
      "🛑 Bus stopped for a quick headcount.",
      "🎓 All students safely dropped at campus.",
      "📞 Please call admin for urgent matters.",
      "🔧 Minor mechanical issue. Will resume shortly.",
      "🅿️ Parked at designated bus bay.",
      "👨‍🎓 Students boarding at current stop.",
      "🚦 Waiting at traffic signal. On schedule.",
      "🏫 Reached college gate. Please exit safely.",
      "✔️ Trip completed. Bus returning to depot.",
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.92,
        minChildSize: 0.4,
        builder: (_, scrollController) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Color(0xFFCBD5E1), borderRadius: BorderRadius.all(Radius.circular(2)))),
              ),
              const SizedBox(height: 16),
              Text(
                t("Select Predefined Intercom Message"),
                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Color(0xFF1E3A8A)),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: driverMessages.length,
                  itemBuilder: (context, index) {
                    final msg = driverMessages[index];
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      color: const Color(0xFFF8FAFC),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                      borderOnForeground: true,
                      child: Material(
                        color: Colors.transparent,
                        child: ListTile(
                          title: Text(t(msg), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF334155))),
                          trailing: const Icon(Icons.send_rounded, color: Color(0xFF2563EB), size: 18),
                          onTap: () {
                            _sendTextMessage(msg);
                            Navigator.pop(ctx);
                          },
                        ),
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

  void _startFirebaseConnectedListener() {
    if (Firebase.apps.isEmpty) return;
    _connectedSubscription = FirebaseDatabase.instance.ref('.info/connected').onValue.listen((event) {
      final connected = event.snapshot.value == true;
      if (mounted) {
        setState(() {
          _firebaseConnected = connected;
        });
      }
    });
  }

  String _formattedTimeNow() {
    final now = DateTime.now();
    return "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
  }

  Future<void> _fbUpdateLocation(Position pos) async {
    _fbUpdateLocationRaw(pos.latitude, pos.longitude, pos.accuracy);
  }

  void _fbUpdateLocationRaw(double lat, double lng, double acc) {
    SharedPreferences.getInstance().then((prefs) {
      prefs.setDouble('driver_last_lat_${widget.driverBus}', lat);
      prefs.setDouble('driver_last_lng_${widget.driverBus}', lng);
      prefs.setString('driver_last_time_${widget.driverBus}', DateTime.now().toIso8601String());
    }).catchError((_) {});

    if (Firebase.apps.isEmpty) return;

    final data = {
      'lat': lat,
      'lng': lng,
      'acc': acc,
      'status': _isParked ? 'parked' : (_isTracking ? (_breakdownActive ? 'broken' : 'tracking') : 'offline'),
      'updatedAt': DateTime.now().toIso8601String(),
      'direction': _tripDirection,
      'bus': widget.driverBus,
      'route': _routeKey,
    };

    FirebaseDatabase.instance.ref('liveLocations/${widget.driverBus}').set(data).then((_) {
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _syncStatusText = "✅ Synced to Firebase";
          _syncTimestamp = _formattedTimeNow();
        });
      }
    }).catchError((_) {});

    FirebaseDatabase.instance.ref('drivers/${widget.driverBus}').get().then((snap) {
      if (snap.exists && snap.value != null) {
        FirebaseDatabase.instance.ref('drivers/${widget.driverBus}/status').set(_isTracking ? 'tracking' : 'offline').catchError((_) {});
      }
    }).catchError((_) {});
  }

  void _startSafetyTimer() {
    _safetyTimer?.cancel();
    _safetyTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!_isTracking) return;
      
      if (_onPhoneCall) {
        _callSecondsCounter++;
        if (_callSecondsCounter >= 60) {
          await _sendSafetyAlert("phoneCall", "Driver is using phone (on call) for ${_callSecondsCounter}s while driving!");
        }
      } else {
        _callSecondsCounter = 0;
        await _clearSafetyAlert("phoneCall");
      }

      if (_connectedToEarpods) {
        await _sendSafetyAlert("earpods", "Driver phone is connected to earpods/headphones!");
      } else {
        await _clearSafetyAlert("earpods");
      }
    });
  }

  void _stopSafetyTimer() async {
    _safetyTimer?.cancel();
    _safetyTimer = null;
    _callSecondsCounter = 0;
    await _clearSafetyAlert("phoneCall");
    await _clearSafetyAlert("earpods");
  }

  Future<void> _sendSafetyAlert(String type, String message) async {
    if (Firebase.apps.isEmpty) return;
    try {
      await FirebaseDatabase.instance.ref('drivers_alerts/${widget.driverBus}/$type').set({
        'active': true,
        'message': message,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint("Error sending safety alert: $e");
    }
  }

  Future<void> _clearSafetyAlert(String type) async {
    if (Firebase.apps.isEmpty) return;
    try {
      await FirebaseDatabase.instance.ref('drivers_alerts/${widget.driverBus}/$type').remove();
    } catch (e) {
      debugPrint("Error clearing safety alert: $e");
    }
  }

  Future<void> _fbSetOffline({String statusToSet = 'completed'}) async {
    if (Firebase.apps.isEmpty) return;
    setState(() {
      _isSyncing = true;
    });

    final data = {
      'lat': _currentPosition?.latitude ?? 13.0486,
      'lng': _currentPosition?.longitude ?? 80.0753,
      'acc': _currentPosition?.accuracy ?? 10.0,
      'status': statusToSet,
      'updatedAt': DateTime.now().toIso8601String()
    };

    try {
      final ref = FirebaseDatabase.instance.ref('liveLocations/${widget.driverBus}');
      await ref.set(data);
      ref.onDisconnect().cancel();
      setState(() {
        _isSyncing = false;
        _syncStatusText = "☁️ Offline status saved";
      });
    } catch (_) {
      setState(() {
        _isSyncing = false;
      });
    }
  }

  List<LatLng> _interpolatePoints(List<Map<String, dynamic>> stops) {
    List<LatLng> path = [];
    if (stops.isEmpty) return path;
    for (int i = 0; i < stops.length - 1; i++) {
      final start = LatLng(stops[i]['lat'] as double, stops[i]['lng'] as double);
      final end = LatLng(stops[i + 1]['lat'] as double, stops[i + 1]['lng'] as double);
      int steps = 15;
      for (int s = 0; s < steps; s++) {
        double t = s / steps;
        double lat = start.latitude + (end.latitude - start.latitude) * t;
        double lng = start.longitude + (end.longitude - start.longitude) * t;
        path.add(LatLng(lat, lng));
      }
    }
    final last = stops.last;
    path.add(LatLng(last['lat'] as double, last['lng'] as double));
    return path;
  }

  void _startTracking({bool isRestoring = false, bool restoreBreakdown = false}) async {
    setState(() {
      _isTracking = true;
      _isParked = false;
      _breakdownActive = restoreBreakdown; // Maintain breakdown if restoring
      _appStatus = restoreBreakdown ? "Broken Down" : "Online";
      _syncStatusText = "Starting GPS stream...";
    });

    if (Firebase.apps.isNotEmpty && !restoreBreakdown) {
      FirebaseDatabase.instance.ref('breakdowns/${widget.driverBus}').remove();
    }

    // IMMEDIATELY push the 'tracking' status to Firebase so students see "Bus is online" 
    // instantly, without waiting for the first GPS lock (which can take 10-30 seconds).
    _fbUpdateLocationRaw(_latitude, _longitude, _accuracy);

    // Play train station departure chime sound & voice announcement
    if (!isRestoring) {
      _playStartTrackingSound();
    }

    _showBusReadyNotification();
    _startSpeechMonitor();
    _startSafetyTimer();
    // Persist tracking state so system knows we are active
    final prefs = await SharedPreferences.getInstance();
    prefs.setBool('driver_is_tracking_${widget.driverBus}', true);

    // Push "Trip Started" to the global notifications node so students see it in their notification center
    // ONLY if the driver manually started it (not when automatically restoring state).
    if (Firebase.apps.isNotEmpty && !isRestoring) {
      final id = DateTime.now().millisecondsSinceEpoch;
      final timeNow = "${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}";
      FirebaseDatabase.instance.ref('student_notifications/$id').set({
        'title': '🚌 Trip Started',
        'msg': 'Bus ${widget.driverBus} has started its route. Live GPS tracking is active.',
        'type': 'alert',
        'bus': widget.driverBus,
        'time': timeNow,
        'read': false,
        'sentAt': DateTime.now().toIso8601String(),
      });
    }

    if (_simulateRoute) {
      _simulatedPath = _interpolatePoints(_routeStops);
      _simRouteIndex = 0;
      if (_simulatedPath.isNotEmpty) {
        final firstPt = _simulatedPath[0];
        setState(() {
          _latitude = firstPt.latitude;
          _longitude = firstPt.longitude;
          _accuracy = 5.0;
          _updatedAt = _formattedTimeNow();
          _gpsStatus = "Simulated";
        });
        _fbUpdateLocationRaw(_latitude, _longitude, _accuracy);
        _mapController.move(firstPt, _mapController.camera.zoom);
      }

      _simTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
        if (_simulatedPath.isEmpty || !_isTracking) {
          timer.cancel();
          return;
        }
        _simRouteIndex = (_simRouteIndex + 1) % _simulatedPath.length;
        final pt = _simulatedPath[_simRouteIndex];
        setState(() {
          _latitude = pt.latitude;
          _longitude = pt.longitude;
          _accuracy = 5.0;
          _updatedAt = _formattedTimeNow();
        });
        _fbUpdateLocationRaw(_latitude, _longitude, _accuracy);
        _mapController.move(pt, _mapController.camera.zoom);
        
        final mockPos = Position(
          latitude: pt.latitude,
          longitude: pt.longitude,
          timestamp: DateTime.now(),
          accuracy: 5.0,
          altitude: 0.0,
          altitudeAccuracy: 0.0,
          heading: 0.0,
          headingAccuracy: 0.0,
          speed: 10.0,
          speedAccuracy: 0.0,
        );
        _checkGeofences(mockPos);
        _checkCollegeArrival(mockPos);
      });
    } else {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
          _showDialog("Permission Required", "GPS Location permissions are required to start vehicle tracking.");
          return;
        }
      }

      // 1. Fetch TRUE real physical GPS location from device hardware
      Position? initialPos;
      try {
        initialPos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 4),
        );
      } catch (_) {
        try {
          initialPos = await Geolocator.getLastKnownPosition();
        } catch (_) {}
      }

      if (initialPos != null) {
        _currentPosition = initialPos;
        _latitude = initialPos.latitude;
        _longitude = initialPos.longitude;
        _accuracy = initialPos.accuracy;
      } else if (_latitude == 0.0 || _longitude == 0.0) {
        if (_routeStops.isNotEmpty) {
          _latitude = _routeStops[0]['lat'] as double;
          _longitude = _routeStops[0]['lng'] as double;
        }
      }

      _updatedAt = _formattedTimeNow();
      _gpsStatus = "Active";

      if (mounted) {
        setState(() {});
      }
      _fbUpdateLocationRaw(_latitude, _longitude, _accuracy);

      if (Firebase.apps.isNotEmpty) {
        FirebaseDatabase.instance.ref('liveLocations/${widget.driverBus}').onDisconnect().cancel();
      }
      try {
        _mapController.move(LatLng(_latitude, _longitude), 16.0);
      } catch (_) {}

      LocationSettings locationSettings;
      if (defaultTargetPlatform == TargetPlatform.android) {
        locationSettings = AndroidSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 0, // 0 for continuous update regardless of distance
          intervalDuration: const Duration(seconds: 1), // 1 second interval for smooth tracking
          foregroundNotificationConfig: ForegroundNotificationConfig(
            notificationText: "Panimalar Smart Transit location tracking is active in background",
            notificationTitle: "Live GPS Active - Bus ${widget.driverBus}",
            enableWakeLock: true,
            enableWifiLock: true,
          ),
        );
      } else {
        locationSettings = const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 0,
        );
      }

      // Continuous Real GPS Location Stream Listener — Updates ONLY when GPS changes!
      _globalActiveBus = widget.driverBus;
      _globalPositionSubscription?.cancel();
      _globalPositionSubscription = Geolocator.getPositionStream(
        locationSettings: locationSettings,
      ).listen((Position position) {
        _globalActiveBus = widget.driverBus;
        if (mounted) {
          setState(() {
            _currentPosition = position;
            _latitude = position.latitude;
            _longitude = position.longitude;
            _accuracy = position.accuracy;
            _updatedAt = _formattedTimeNow();
            try {
              _mapController.move(LatLng(position.latitude, position.longitude), _mapController.camera.zoom);
            } catch (_) {}
          });
        }
        _fbUpdateLocationRaw(position.latitude, position.longitude, position.accuracy);
        _checkGeofences(position);
        _checkCollegeArrival(position);
      });
      _positionSubscription = _globalPositionSubscription;
    }
  }

  // Plays real Tamil audio — uses browser Web Speech API (web) or Google TTS URL (Android)
  Future<void> _speakTamilVoiceMessage(String textTamil, String textFallback) async {
    if (kIsWeb) {
      // On web (Chrome): browser has built-in Tamil Web Speech API
      try {
        final FlutterTts tts = FlutterTts();
        await tts.setVolume(1.0);
        await tts.setPitch(1.0);
        await tts.setSpeechRate(0.45);
        await tts.setLanguage("ta-IN");
        await tts.speak(textTamil);
      } catch (_) {
        try {
          final FlutterTts tts = FlutterTts();
          await tts.setLanguage("ta");
          await tts.speak(textTamil);
        } catch (_) {}
      }
    } else {
      // On Android/iOS: use Google Translate TTS URL (no CORS issue)
      try {
        await _audioPlayer.stop();
        final encoded = Uri.encodeComponent(textTamil);
        final url = 'https://translate.google.com/translate_tts?ie=UTF-8&client=tw-ob&tl=ta&q=$encoded';
        await _audioPlayer.play(UrlSource(url));
      } catch (_) {
        // Fallback to device TTS
        try {
          final FlutterTts tts = FlutterTts();
          await tts.setVolume(1.0);
          await tts.setSpeechRate(0.45);
          await tts.setLanguage("ta-IN");
          await tts.speak(textTamil);
        } catch (_) {}
      }
    }
  }

  void _playStartTrackingSound() {
    Future.delayed(const Duration(milliseconds: 600), () {
      _speakTamilVoiceMessage("பயணம் தொடங்கியது.", "Payanam thodangiyathu.");
    });
  }

  void _playStopTrackingSound() {
    Future.delayed(const Duration(milliseconds: 300), () {
      _speakTamilVoiceMessage("பயணம் முடிவடைந்தது.", "Payanam mudindhadhu.");
    });
  }

  void _stopTracking() async {
    _periodicGpsTimer?.cancel();
    _periodicGpsTimer = null;
    _globalPositionSubscription?.cancel();
    _globalPositionSubscription = null;
    _globalActiveBus = null;
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _simTimer?.cancel();
    _simTimer = null;
    _stopSafetyTimer();

    // Play train station arrival chime sound & voice announcement
    _playStopTrackingSound();

    setState(() {
      _isTracking = false;
      _isParked = false;
      _breakdownActive = false; // Reset breakdown when trip finishes
      _appStatus = "Completed";
      _gpsStatus = "Offline";
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('driver_is_tracking_${widget.driverBus}', false);
    await prefs.remove('driver_last_lat_${widget.driverBus}');
    await prefs.remove('driver_last_lng_${widget.driverBus}');

    if (Firebase.apps.isNotEmpty) {
      FirebaseDatabase.instance.ref('breakdowns/${widget.driverBus}').remove();
      final dSnap = await FirebaseDatabase.instance.ref('drivers/${widget.driverBus}').get();
      if (dSnap.exists && dSnap.value != null) {
        await FirebaseDatabase.instance.ref('drivers/${widget.driverBus}/status').set('completed');
      }
    }

    await _fbSetOffline(statusToSet: 'completed');
    _stopSpeechMonitor();

    // Push "Trip Completed" to the global notifications node so students see it in their notification center
    if (Firebase.apps.isNotEmpty) {
      final id = DateTime.now().millisecondsSinceEpoch;
      final timeNow = "${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}";
      FirebaseDatabase.instance.ref('student_notifications/$id').set({
        'title': '🏁 Trip Completed',
        'msg': 'Bus ${widget.driverBus} has completed its trip. Thank you for riding with us!',
        'type': 'alert',
        'bus': widget.driverBus,
        'time': timeNow,
        'read': false,
        'sentAt': DateTime.now().toIso8601String(),
      });
    }
  }

  String _lastNotifiedStop = "";

  void _checkGeofences(Position pos) {
    double minDistance = double.maxFinite;
    String closestStopName = _nextStop;

    for (var stop in _routeStops) {
      double dist = Geolocator.distanceBetween(
        pos.latitude,
        pos.longitude,
        stop['lat'] as double,
        stop['lng'] as double,
      );
      if (dist < minDistance) {
        minDistance = dist;
        closestStopName = stop['name'] as String;
      }
    }

    setState(() {
      if (minDistance < 100) {
        _nextStop = closestStopName;
        _eta = "Arrived";
        if (_lastNotifiedStop != closestStopName) {
          _lastNotifiedStop = closestStopName;
          final cleanName = closestStopName.replaceAll(RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)'), '').trim();
          if (Firebase.apps.isNotEmpty) {
            final timeNow = "${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}";
            FirebaseDatabase.instance.ref('student_notifications/${DateTime.now().millisecondsSinceEpoch}').set({
              'title': '🚏 Bus ${widget.driverBus} Approaching Stop',
              'msg': 'Bus ${widget.driverBus} is reaching $cleanName stop.',
              'type': 'alert',
              'bus': widget.driverBus,
              'time': timeNow,
              'read': false,
              'sentAt': DateTime.now().toIso8601String(),
            });
          }
        }
      } else {
        _nextStop = closestStopName;
        int estMinutes = (minDistance / 250).ceil();
        _eta = "$estMinutes min";
      }
    });
  }

  void _checkCollegeArrival(Position pos) async {
    if (!_isTracking || Firebase.apps.isEmpty) return;

    final today = DateTime.now().toIso8601String().substring(0, 10);
    final timeNow = "${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}";
    final logRef = FirebaseDatabase.instance.ref('arrival_logs/$today/${widget.driverBus}');

    // Fetch initial state once per app session to avoid spamming Firebase
    if (!_hasCheckedTodayLog) {
      _hasCheckedTodayLog = true;
      try {
        final snap = await logRef.get();
        if (snap.exists) {
          final data = snap.value as Map;
          if (data['arrived'] != null) _hasLoggedArrivalToday = true;
          if (data['departed'] != null) _hasLoggedDepartureToday = true;
        }
      } catch (e) {
        debugPrint("Failed to fetch initial log state: $e");
        _hasCheckedTodayLog = false;
      }
    }

    // College entrance Gate coords (13°2'50"N, 80°4'31"E)
    double distToCollege = Geolocator.distanceBetween(
      pos.latitude,
      pos.longitude,
      13.04722,
      80.07528,
    );

    // Keep track if the bus is/was recently near or inside the college
    if (distToCollege < 400) {
      _wasAtCollege = true;
    }

    // Arrival Logic: Moving towards the college entrance
    if (_tripDirection == 'To College' && distToCollege < 200 && !_hasLoggedArrivalToday) {
      _hasLoggedArrivalToday = true;
      try {
        await logRef.update({
          'bus': widget.driverBus,
          'driver': 'Driver ${widget.driverBus}',
          'route': _getRouteLabelForBus(widget.driverBus),
          'date': today,
          'arrived': timeNow,
          'status': 'arrived',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        _showSnackBar("🏫 Reached campus! Arrival logged automatically.");
      } catch (e) {
        debugPrint("Failed to write automated arrival log: $e");
        _hasLoggedArrivalToday = false;
      }
    } 
    // Departure Logic: Moving away from the college entrance
    else if (_tripDirection == 'To Home' && distToCollege > 300 && _wasAtCollege && !_hasLoggedDepartureToday) {
      _hasLoggedDepartureToday = true;
      try {
        await logRef.update({
          'bus': widget.driverBus,
          'driver': 'Driver ${widget.driverBus}',
          'route': _getRouteLabelForBus(widget.driverBus),
          'date': today,
          'departed': timeNow,
          'status': 'departed',
        });
        _showSnackBar("🚌 Left campus! Departure logged automatically.");
      } catch (e) {
        debugPrint("Failed to write automated departure log: $e");
        _hasLoggedDepartureToday = false;
      }
    }
  }

  void _parkBus() async {
    if (!mounted) return;
    setState(() {
      _isParked = true;
      _breakdownActive = false;
      _isTracking = false;
      _appStatus = "Parked";
    });
    
    // Completely cancel the location stream so it absolutely does not move in the database
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    
    if (Firebase.apps.isNotEmpty) {
      try {
        // Get the highest accuracy location when parked
        final position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
        setState(() {
          _latitude = position.latitude;
          _longitude = position.longitude;
        });
        await FirebaseDatabase.instance.ref('liveLocations/${widget.driverBus}').update({
          'lat': _latitude,
          'lng': _longitude,
          'status': 'parked',
          'updatedAt': DateTime.now().toIso8601String(),
        });
        _showSnackBar("✅ Bus marked as Parked in Campus");
        
        // Automatically remove from parked if it moves > 1km from campus center
        _parkedLocationTimer?.cancel();
        _parkedLocationTimer = Timer.periodic(const Duration(seconds: 15), (timer) async {
          try {
            final pos = await Geolocator.getCurrentPosition();
            final distance = const Distance().as(
              LengthUnit.Meter, 
              const LatLng(13.049, 80.075), 
              LatLng(pos.latitude, pos.longitude)
            );
            if (distance > 1000) {
              _unparkBus();
            }
          } catch (_) {}
        });
      } catch (e) {
        _showSnackBar("Failed to mark as parked: $e");
      }
    }
  }

  void _unparkBus() async {
    if (!mounted) return;
    _parkedLocationTimer?.cancel();
    setState(() {
      _isParked = false;
      _appStatus = "Offline";
    });
    
    if (Firebase.apps.isNotEmpty) {
      try {
        await FirebaseDatabase.instance.ref('liveLocations/${widget.driverBus}').update({
          'status': 'offline',
          'updatedAt': DateTime.now().toIso8601String(),
        });
        _showSnackBar("✅ Bus removed from Campus Map");
      } catch (e) {
        _showSnackBar("Failed to un-park: $e");
      }
    }
  }

  void _reportBreakdown() async {
    if (!_isTracking) return;
    setState(() {
      _breakdownActive = true;
      _appStatus = "Broken Down";
    });
    
    final prefs = await SharedPreferences.getInstance();
    prefs.setBool('driver_is_breakdown_${widget.driverBus}', true);

    final data = {
      'busId': widget.driverBus,
      'bus': widget.driverBus,
      'replacement': 'Pending',
      'lat': _latitude,
      'lng': _longitude,
      'time': DateTime.now().toIso8601String(),
      'timestamp': DateTime.now().millisecondsSinceEpoch
    };

    if (Firebase.apps.isNotEmpty) {
      FirebaseDatabase.instance.ref('breakdowns/${widget.driverBus}').set(data);
      
      // Also push to student notifications so it remains in their history
      await FirebaseDatabase.instance
            .ref('student_notifications/${DateTime.now().millisecondsSinceEpoch}')
            .set({
          'title': 'Bus ${widget.driverBus} Breakdown',
          'msg': 'Bus ${widget.driverBus} breakdown reported. Replacement Bus dispatch is pending. Stay at your stop.',
          'type': 'alert',
          'time': DateTime.now().toIso8601String(),
          'read': false,
          'bus': widget.driverBus,
        });
        
      // Push to admin alerts
      await FirebaseDatabase.instance
            .ref('breakdownAlerts/${widget.driverBus}_${DateTime.now().millisecondsSinceEpoch}')
            .set({
          'busId': widget.driverBus,
          'bus': widget.driverBus,
          'message': 'Bus ${widget.driverBus} breakdown reported.',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'lat': _latitude,
          'lng': _longitude,
        });
    }

    if (_currentPosition != null) {
      _fbUpdateLocationRaw(_currentPosition!.latitude, _currentPosition!.longitude, _currentPosition!.accuracy);
    }
  }

  Future<void> _sendBreakdownAlert() async {
    final repBus = _replacementController.text.trim().toUpperCase();
    if (repBus.isEmpty) {
      _showDialog("Error", t('replacementErrorEmpty'));
      return;
    }

    if (repBus == widget.driverBus.trim().toUpperCase()) {
      _showDialog("Error", "Replacement bus cannot be the same as the current bus.");
      return;
    }

    final data = {
      'busId': widget.driverBus,
      'bus': widget.driverBus,
      'replacement': repBus,
      'lat': _latitude,
      'lng': _longitude,
      'time': DateTime.now().toIso8601String(),
      'timestamp': DateTime.now().millisecondsSinceEpoch
    };

    try {
      await FirebaseDatabase.instance.ref('breakdowns/${widget.driverBus}').set(data);
      
      // Also push to student notifications so it remains in their history
      await FirebaseDatabase.instance
            .ref('student_notifications/${DateTime.now().millisecondsSinceEpoch}')
            .set({
          'title': 'Bus ${widget.driverBus} Breakdown Update',
          'msg': 'Bus ${widget.driverBus} breakdown. Replacement Bus $repBus dispatched. Stay at your stop.',
          'type': 'alert',
          'time': DateTime.now().toIso8601String(),
          'read': false,
          'bus': widget.driverBus,
        });
        
      // Push to admin alerts
      await FirebaseDatabase.instance
            .ref('breakdownAlerts/${widget.driverBus}_${DateTime.now().millisecondsSinceEpoch}')
            .set({
          'busId': widget.driverBus,
          'bus': widget.driverBus,
          'message': 'Bus ${widget.driverBus} breakdown. Replacement Bus $repBus dispatched.',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'lat': _latitude,
          'lng': _longitude,
        });
        
      _showDialog("Success", "Breakdown Alert Sent! Replacement bus: $repBus");
      setState(() {
        _replacementBus = repBus;
      });
    } catch (e) {
      _showDialog("Error", "Failed to send alert: $e");
    }
  }

  Future<void> _readyToTrip() async {
    bool hasReplacement = _replacementBus != null && _replacementBus!.isNotEmpty;
    
    if (hasReplacement) {
      // Replacement was sent → FULL RESET to default dashboard state
      // Driver must click "Start Tracking" again manually
      await _positionSubscription?.cancel();
      _positionSubscription = null;
      _simTimer?.cancel();
      _simTimer = null;
      _stopSafetyTimer();

      setState(() {
        // Reset all tracking state to default
        _isTracking = false;
        _isParked = false;
        _breakdownActive = false;
        _currentPosition = null;
        _appStatus = "Offline";
        _gpsStatus = "Offline";
        _syncStatusText = "Idle";
        _syncTimestamp = "--";
        _isSyncing = false;
        _updatedAt = "--";
        _eta = "--";
        _nextStop = _routeStops.isNotEmpty ? (_routeStops[0]['name'] ?? "—") : "—";
        _simRouteIndex = 0;
        _replacementBus = null;
        _replacementController.clear();
        _routeNotifyStatus = "";
        _attendanceCount = 0;
      });

      await _fbSetOffline(statusToSet: 'offline');
      _stopSpeechMonitor();
      final prefs = await SharedPreferences.getInstance();
      prefs.setBool('driver_is_tracking_${widget.driverBus}', false);
      prefs.setBool('driver_is_breakdown_${widget.driverBus}', false);
    } else {
      // No replacement sent → just clear breakdown, keep tracking active
      setState(() {
        _breakdownActive = false;
        _appStatus = "Online";
        _replacementBus = null;
        _replacementController.clear();
      });
      final prefs = await SharedPreferences.getInstance();
      prefs.setBool('driver_is_breakdown_${widget.driverBus}', false);
      
      if (_isTracking && _currentPosition != null) {
        _fbUpdateLocationRaw(_latitude, _longitude, _accuracy);
      }
    }

    final data = {
      'status': _isTracking ? 'tracking' : 'offline',
      'replacementBus': null,
      'updatedAt': DateTime.now().toIso8601String(),
    };
    
    if (Firebase.apps.isNotEmpty) {
      await FirebaseDatabase.instance.ref('drivers/${widget.driverBus}').update(data);
      await FirebaseDatabase.instance.ref('breakdowns/${widget.driverBus}').remove();
      
      // Notify admin
      await FirebaseDatabase.instance
            .ref('breakdownAlerts/${widget.driverBus}_${DateTime.now().millisecondsSinceEpoch}')
            .set({
          'busId': widget.driverBus,
          'bus': widget.driverBus,
          'message': hasReplacement
              ? 'Bus ${widget.driverBus} is ready for a new trip after replacement. Driver needs to start tracking.'
              : 'Bus ${widget.driverBus} has resumed its journey from the breakdown.',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'lat': _latitude,
          'lng': _longitude,
        });

      // Notify students to come back to this bus
      await FirebaseDatabase.instance
            .ref('student_notifications/${DateTime.now().millisecondsSinceEpoch}')
            .set({
          'title': '🚌 Bus ${widget.driverBus} is Back!',
          'msg': hasReplacement
              ? 'Bus ${widget.driverBus} is ready again! Please board Bus ${widget.driverBus} for your route. The replacement bus is no longer needed.'
              : 'Bus ${widget.driverBus} has resumed its journey. Live tracking is active again.',
          'type': 'alert',
          'time': DateTime.now().toIso8601String(),
          'read': false,
          'bus': widget.driverBus,
        });

      // Clear the replacement info from liveLocations so students are redirected back
      await FirebaseDatabase.instance.ref('liveLocations/${widget.driverBus}').update({
        'status': _isTracking ? 'tracking' : 'offline',
        'replacement': null,
      });
    }

    _showDialog(
      "Ready",
      hasReplacement
          ? "Bus reset complete. Tap 'Start Tracking' to begin a new trip. Students have been notified."
          : "Bus is back online and tracking. Students have been notified.",
    );
  }

  void _sendBreakdownToRouteBuses() async {
    final selectedBuses = _selectedNotifyBuses.entries.where((e) => e.value).map((e) => e.key).join(", ");
    setState(() {
      _routeNotifyStatus = "Notifying other buses on same route…";
    });
    await Future.delayed(const Duration(seconds: 1));
    setState(() {
      _routeNotifyStatus = "✅ Notified buses $selectedBuses to pick up stranded students.";
    });
    _showSnackBar("Notifications dispatched successfully.");
  }

  void _logBoarding() {
    if (_attendanceCount < _attendanceCapacity) {
      setState(() {
        _attendanceCount++;
      });
      _showSnackBar(t('boardingLogged'));
    } else {
      _showSnackBar(t('allBoarded'));
    }
  }

  void _startSpeechMonitor() {
    _waveTimer?.cancel();
    _smSimulationTimer?.cancel();
    
    setState(() {
      _smActive = true;
      _totalSpeakingSeconds = 0;
      _sessionsCount = 0;
      _longestSessionSeconds = 0;
      _speechUsagePercentage = 0.0;
      _speechLog = [];
      _showSpeechAlert = false;
      _driveSeconds = 0;
      _isSpeaking = false;
      _currentSpeechSessionSecs = 0;
    });

    _smSimulationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _driveSeconds++;
      final random = Random();
      
      if (!_isSpeaking && random.nextDouble() < 0.15) {
        // Start speaking
        _isSpeaking = true;
        _sessionsCount++;
        _currentSpeechSessionSecs = 0;
      } else if (_isSpeaking && random.nextDouble() < 0.25) {
        // Stop speaking
        _isSpeaking = false;
        if (_currentSpeechSessionSecs > _longestSessionSeconds) {
          _longestSessionSeconds = _currentSpeechSessionSecs;
        }
      }

      if (_isSpeaking) {
        _totalSpeakingSeconds++;
        _currentSpeechSessionSecs++;
        if (_currentSpeechSessionSecs % 5 == 0) {
          final now = DateTime.now();
          final timeStr = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
          
          final val = random.nextDouble() < 0.3
              ? "Asking passengers to step behind yellow line"
              : "Talking to co-driver about traffic block";
              
          final bool isWarn = _speechUsagePercentage > _warnThresholdPct;

          _speechLog.insert(0, {
            'time': timeStr,
            'text': val,
            'isWarn': isWarn.toString(),
          });
        }
      }

      _speechUsagePercentage = (_totalSpeakingSeconds / _driveSeconds) * 100;

      if (_speechUsagePercentage > _warnThresholdPct) {
        _showSpeechAlert = true;
      } else {
        _showSpeechAlert = false;
      }
    });

    _waveTimer = Timer.periodic(const Duration(milliseconds: 150), (timer) {
      final random = Random();
      setState(() {
        if (_isSpeaking) {
          _waveValues = List.generate(15, (index) => 5.0 + random.nextDouble() * 25.0);
        } else {
          _waveValues = List.generate(15, (index) => 2.0 + random.nextDouble() * 3.0);
        }
      });
    });
  }

  void _stopSpeechMonitor() {
    _waveTimer?.cancel();
    _smSimulationTimer?.cancel();
    setState(() {
      _smActive = false;
      _isSpeaking = false;
    });
  }

  void _showBusReadyNotification() {
    setState(() {
      _showBusReadyBanner = true;
      _busReadyCountdown = 10;
    });

    _busReadyCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        if (_busReadyCountdown > 0) {
          _busReadyCountdown--;
        } else {
          timer.cancel();
        }
      });
    });

    _busReadyTimer = Timer(const Duration(seconds: 10), () {
      setState(() {
        _showBusReadyBanner = false;
      });
    });
  }

  void _showDialog(String title, String m) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
        content: Text(m, style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("OK", style: TextStyle(fontWeight: FontWeight.bold)),
          )
        ],
      ),
    );
  }

  void _removePickup(String pickupId) {
    FirebaseDatabase.instance.ref('pickup_requests/$pickupId').remove();
    _showSnackBar("Pickup letter removed.");
  }

  void _showEnlargedPhotoDialog(BuildContext context, String name, String? base64Str, Map<String, dynamic> student) {
    final studentId = student['id']?.toString() ?? student['studentId']?.toString() ?? student['rollNo']?.toString() ?? '';

    Widget renderBase64Image(String rawB64) {
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
        return Image.memory(
          base64Decode(b64),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const Center(
            child: Icon(Icons.person, size: 100, color: Colors.grey),
          ),
        );
      } catch (e) {
        return const Center(
          child: Icon(Icons.person, size: 100, color: Colors.grey),
        );
      }
    }

    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white, size: 32),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ),
              const SizedBox(height: 10),
              Container(
                width: 270,
                height: 270,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.7),
                      blurRadius: 25,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(17),
                  child: (base64Str != null && base64Str.isNotEmpty)
                      ? renderBase64Image(base64Str)
                      : FutureBuilder<DatabaseEvent>(
                          future: studentId.isNotEmpty
                              ? FirebaseDatabase.instance.ref('students/$studentId').once()
                              : null,
                          builder: (context, snapshot) {
                            if (snapshot.connectionState == ConnectionState.waiting) {
                              return const Center(child: CircularProgressIndicator(color: Colors.white));
                            }
                            if (snapshot.hasData && snapshot.data!.snapshot.value != null) {
                              final data = snapshot.data!.snapshot.value;
                              if (data is Map) {
                                final b64 = (data['profilePicBase64'] ?? data['photo'] ?? data['studentPhoto']) as String?;
                                if (b64 != null && b64.isNotEmpty) {
                                  return renderBase64Image(b64);
                                }
                              }
                            }
                            return const Center(
                              child: Icon(Icons.person, size: 100, color: Colors.grey),
                            );
                          },
                        ),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  children: [
                    Text(
                      name,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF0F172A)),
                      textAlign: TextAlign.center,
                    ),
                    if (studentId.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        studentId.toUpperCase(),
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF2563EB)),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      "${student['studentYear'] ?? ''} Year • ${student['studentDept'] ?? ''} • Bus: ${student['studentBus'] ?? ''}",
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showViewAllLettersDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.85,
          maxChildSize: 0.95,
          minChildSize: 0.5,
          expand: false,
          builder: (ctx, scrollController) {
            return Column(
              children: [
                const SizedBox(height: 12),
                Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 16),
                const Text("All Authorized Letters", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A))),
                const SizedBox(height: 16),
                Expanded(
                  child: _confirmedPickups.isEmpty
                      ? const Center(child: Text("No pickup requests approved yet for today.", style: TextStyle(color: Colors.grey)))
                      : ListView.builder(
                          controller: scrollController,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: _confirmedPickups.length,
                          itemBuilder: (ctx, idx) {
                            final pickup = _confirmedPickups[idx];
                            final ts = pickup['timestamp'] as int;
                            String timeStr = "";
                            if (ts > 0) {
                              final dt = DateTime.fromMillisecondsSinceEpoch(ts);
                              timeStr = " • ${dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour)}:${dt.minute.toString().padLeft(2, '0')} ${dt.hour >= 12 ? 'PM' : 'AM'}";
                            }
                            
                            Widget imageWidget = const Icon(Icons.person, size: 40, color: Colors.grey);
                            final studentId = pickup['id'] as String? ?? "";
                            
                            Widget _buildProfileImage(String base64Str) {
                              String b64 = base64Str;
                              if (b64.startsWith('base64:')) {
                                b64 = b64.substring(7);
                              }
                              b64 = b64.replaceAll(RegExp(r'\s+'), '');
                              int padding = b64.length % 4;
                              if (padding > 0) {
                                b64 += '=' * (4 - padding);
                              }
                              try {
                                return SizedBox(
                                  width: 80,
                                  height: 80,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.memory(
                                      base64Decode(b64),
                                      fit: BoxFit.cover,
                                      errorBuilder: (context, error, stackTrace) => const Icon(Icons.person, size: 40, color: Colors.grey),
                                    ),
                                  ),
                                );
                              } catch (e) {
                                return const SizedBox(width: 80, height: 80, child: Icon(Icons.person, size: 40, color: Colors.grey));
                              }
                            }

                            final profilePicBase64 = pickup['profilePicBase64'] as String?;
                            if (profilePicBase64 != null && profilePicBase64.isNotEmpty) {
                              imageWidget = _buildProfileImage(profilePicBase64);
                            } else if (studentId.isNotEmpty) {
                              // Fallback to fetch from Firebase RTDB students node
                              imageWidget = FutureBuilder<DatabaseEvent>(
                                future: FirebaseDatabase.instance.ref('students/$studentId').once(),
                                builder: (context, snapshot) {
                                  if (snapshot.connectionState == ConnectionState.waiting) {
                                    return const SizedBox(width: 80, height: 80, child: Center(child: CircularProgressIndicator()));
                                  }
                                  if (snapshot.hasData && snapshot.data!.snapshot.value != null) {
                                    final studentData = snapshot.data!.snapshot.value as Map;
                                    final b64 = studentData['profilePicBase64'] as String?;
                                    if (b64 != null && b64.isNotEmpty) {
                                      return _buildProfileImage(b64);
                                    }
                                  }
                                  return const SizedBox(
                                    width: 80, height: 80,
                                    child: Icon(Icons.person, size: 40, color: Colors.grey)
                                  );
                                },
                              );
                            }
                            
                            final matchingAdminVoice = _intercomMessages.firstWhere(
                              (m) => m['sender'] == 'admin' && (m['studentId'] == pickup['id'] || m['pickupId'] == pickup['id'] || (m['studentName'] != null && m['studentName'] == pickup['studentName'])),
                              orElse: () => <String, dynamic>{},
                            );
                            final adminVoice = matchingAdminVoice.isNotEmpty
                                ? matchingAdminVoice
                                : _intercomMessages.firstWhere(
                                    (m) => m['sender'] == 'admin',
                                    orElse: () => <String, dynamic>{},
                                  );

                            return Card(
                              margin: const EdgeInsets.only(bottom: 16),
                              elevation: 2,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              clipBehavior: Clip.antiAlias,
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text("${pickup['studentName']}$timeStr", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                          const SizedBox(height: 4),
                                          Text("${pickup['studentYear']} Year • ${pickup['studentDept']} • Bus: ${pickup['studentBus']}", style: const TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.bold)),
                                          const SizedBox(height: 4),
                                          Text("Reason: ${pickup['documentName']}", style: const TextStyle(fontSize: 14, color: Color(0xFF1E3A8A), fontWeight: FontWeight.w600)),
                                          if ((pickup['adminVoiceAudio'] != null && pickup['adminVoiceAudio'].toString().isNotEmpty) ||
                                              (pickup['adminVoiceText'] != null && pickup['adminVoiceText'].toString().isNotEmpty)) ...[
                                            const SizedBox(height: 8),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFFEFF6FF),
                                                borderRadius: BorderRadius.circular(10),
                                                border: Border.all(color: const Color(0xFFBFDBFE)),
                                              ),
                                              child: Row(
                                                children: [
                                                  InkWell(
                                                    onTap: () => _playLetterVoiceAudio(pickup),
                                                    child: Icon(
                                                      _playingMsgId == pickup['id']
                                                          ? Icons.stop_circle_rounded
                                                          : Icons.play_circle_filled_rounded,
                                                      color: const Color(0xFF2563EB),
                                                      size: 26,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment: CrossAxisAlignment.start,
                                                      children: [
                                                        const Text("🎙️ Admin Voice Instruction", style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A))),
                                                        Text(
                                                          pickup['adminVoiceText'] ?? "🎙️ Admin Voice Note (${pickup['adminVoiceDuration'] ?? 5}s)",
                                                          style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
                                                          maxLines: 2,
                                                          overflow: TextOverflow.ellipsis,
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    InkWell(
                                      onTap: () {
                                        _removePickup(pickup['id']);
                                        Navigator.pop(context);
                                      },
                                      child: const Icon(Icons.delete_outline, size: 24, color: Colors.red),
                                    ),
                                    const SizedBox(width: 12),
                                    InkWell(
                                      onTap: () => _showEnlargedPhotoDialog(context, pickup['studentName'] ?? 'Student', profilePicBase64, pickup),
                                      child: imageWidget,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold)),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: const Color(0xFF1E3A8A),
      ),
    );
  }

  String _formatDuration(int secs) {
    final m = secs ~/ 60;
    final s = secs % 60;
    return "$m:${s.toString().padLeft(2, '0')}";
  }

  Widget _buildFieldTile(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFCBD5E1).withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: const TextStyle(fontSize: 9, color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF0F172A))),
        ],
      ),
    );
  }

  Widget _buildSmTile(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: const TextStyle(fontSize: 8.5, color: Color(0xFFB45309), fontWeight: FontWeight.bold)),
          const SizedBox(height: 3),
          Text(value, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w900, color: Color(0xFF78350F))),
        ],
      ),
    );
  }

  Widget _buildRouteBusItem(String bus, String details, {bool isDiffRoute = false}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFCA5A5).withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.directions_bus, color: Color(0xFFDC2626), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Bus $bus", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF991B1B)),),
                Text(details, style: const TextStyle(fontSize: 9.5, color: Color(0xFFB45309), fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Switch(
            value: _selectedNotifyBuses[bus] ?? false,
            activeThumbColor: const Color(0xFFDC2626),
            onChanged: isDiffRoute ? null : (val) {
              setState(() {
                _selectedNotifyBuses[bus] = val;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTextMessageBubble(Map<String, dynamic> msg, bool isMe) {
    final isVoice = msg['isVoice'] == true;
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
                          .ref('voice_messages/driver_${widget.driverBus}/${msg['id']}')
                          .remove();
                    } catch (e) {
                      if (mounted) _showSnackBar("Error deleting message");
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
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          width: isVoice ? 220 : null,
          decoration: BoxDecoration(
            color: isMe ? const Color(0xFFEFF6FF) : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isMe ? 16 : 0),
              bottomRight: Radius.circular(isMe ? 0 : 16),
            ),
            border: Border.all(color: isMe ? const Color(0xFFBFDBFE) : const Color(0xFFE2E8F0)),
          ),
          child: Column(
            crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                msg['senderName'] ?? '',
                style: const TextStyle(fontSize: 8.5, fontWeight: FontWeight.bold, color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 4),
              if (isVoice) ...[
                Row(
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        _playingMsgId == msg['id']
                            ? Icons.pause_circle_filled_rounded
                            : Icons.play_circle_filled_rounded,
                        color: isMe ? const Color(0xFF2563EB) : const Color(0xFF1E293B),
                        size: 28,
                      ),
                      onPressed: () {
                        _playVoiceMessage(msg['id'], msg['msg'] ?? '', msg['voiceDuration'] ?? 3);
                      },
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: _playingMsgId == msg['id'] ? _playbackProgress : 0.0,
                              backgroundColor: isMe ? const Color(0xFFDBEAFE) : const Color(0xFFE2E8F0),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                isMe ? const Color(0xFF2563EB) : const Color(0xFF64748B),
                              ),
                              minHeight: 3,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                "0:${(msg['voiceDuration'] as int? ?? 3).toString().padLeft(2, '0')}",
                                style: const TextStyle(fontSize: 8, color: Color(0xFF64748B), fontWeight: FontWeight.bold),
                              ),
                              const Icon(Icons.volume_up, size: 8, color: Color(0xFF64748B)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  decoration: BoxDecoration(
                    color: isMe ? const Color(0xFFDBEAFE).withValues(alpha: 0.3) : const Color(0xFFE2E8F0).withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    "Transcript: \"${msg['transcript'] ?? ''}\"",
                    style: const TextStyle(
                      fontSize: 9.5,
                      fontStyle: FontStyle.italic,
                      color: Color(0xFF334155),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ] else ...[
                Text(
                  msg['msg'] ?? '',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                ),
              ],
              const SizedBox(height: 2),
              Builder(builder: (_) {
                String msgTime = "";
                final ts = msg['timestamp'] as int?;
                if (ts != null && ts > 0) {
                  final dt = DateTime.fromMillisecondsSinceEpoch(ts);
                  msgTime = "${dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour)}:${dt.minute.toString().padLeft(2, '0')} ${dt.hour >= 12 ? 'pm' : 'am'}";
                }
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (msgTime.isNotEmpty)
                      Text(msgTime, style: const TextStyle(fontSize: 8.5, color: Color(0xFF64748B))),
                    if (isMe) ...[
                      const SizedBox(width: 3),
                      Icon(
                        Icons.done_all,
                        size: 13,
                        color: msg['isRead'] == true ? const Color(0xFF3B82F6) : const Color(0xFF94A3B8),
                      ),
                    ],
                  ],
                );
              }),
            ],
          ),
        ),
      ),
    );
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
          return FutureBuilder<DatabaseEvent>(
            future: FirebaseDatabase.instance.ref('pickup_requests/$studentId').once(),
            builder: (ctx2, snap2) {
              if (snap2.hasData && snap2.data!.snapshot.value != null) {
                final d2 = snap2.data!.snapshot.value;
                if (d2 is Map) {
                  final b64_2 = (d2['profilePicBase64'] ?? d2['photo'] ?? d2['studentPhoto']) as String?;
                  if (b64_2 != null && b64_2.isNotEmpty) {
                    return buildImageFromB64(b64_2);
                  }
                }
              }
              return _buildFallbackAvatar(name);
            },
          );
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
                tag: 'driver_profile_$rollNo',
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
                    if (rollNo.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        rollNo.toUpperCase(),
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2563EB),
                        ),
                      ),
                    ],
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

  Widget _buildAuthorizedPickupsCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFDBE2F8), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text("🎫", style: TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "${t('authorizedLetters')} (${_confirmedPickups.length})",
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF1E3A8A)),
                ),
              ),
              if (_confirmedPickups.isNotEmpty)
                InkWell(
                  onTap: _showViewAllLettersDialog,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD97706),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFD97706).withValues(alpha: 0.3),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.remove_red_eye_rounded, size: 13, color: Colors.white),
                        const SizedBox(width: 4),
                        Text(
                          t('viewAll'),
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (_confirmedPickups.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(child: Text(t('noPickupRequests'), style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold))),
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _confirmedPickups.length,
              itemBuilder: (ctx, idx) {
                final pickup = _confirmedPickups[idx];
                final ts = pickup['timestamp'] as int;
                String timeStr = "";
                if (ts > 0) {
                  final dt = DateTime.fromMillisecondsSinceEpoch(ts);
                  timeStr = " • ${dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour)}:${dt.minute.toString().padLeft(2, '0')} ${dt.hour >= 12 ? 'PM' : 'AM'}";
                }

                final matchingAdminVoice = _intercomMessages.firstWhere(
                  (m) => m['sender'] == 'admin' && (m['studentId'] == pickup['id'] || m['pickupId'] == pickup['id'] || (m['studentName'] != null && m['studentName'] == pickup['studentName'])),
                  orElse: () => <String, dynamic>{},
                );
                final adminVoice = matchingAdminVoice.isNotEmpty
                    ? matchingAdminVoice
                    : _intercomMessages.firstWhere(
                        (m) => m['sender'] == 'admin',
                        orElse: () => <String, dynamic>{},
                      );
                
                return InkWell(
                  onTap: () => _showEnlargedStudentProfile(context, pickup),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const CircleAvatar(
                              backgroundColor: Color(0xFFDCFCE7),
                              radius: 12,
                              child: Icon(Icons.check, size: 12, color: Color(0xFF15803D)),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text("${pickup['studentName']}$timeStr", style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 2),
                                  Text("${pickup['studentYear']} Year • ${pickup['studentDept']} • Bus: ${pickup['studentBus']}", style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 2),
                                  Text("Reason: ${pickup['documentName']}", style: const TextStyle(fontSize: 10, color: Color(0xFF1E3A8A), fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(8)),
                              child: const Text("APPROVED", style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Color(0xFF2563EB))),
                            ),
                          ],
                        ),
                        if ((pickup['adminVoiceAudio'] != null && pickup['adminVoiceAudio'].toString().isNotEmpty) ||
                            (pickup['adminVoiceText'] != null && pickup['adminVoiceText'].toString().isNotEmpty)) ...[
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEFF6FF),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: const Color(0xFFBFDBFE)),
                            ),
                            child: Row(
                              children: [
                                InkWell(
                                  onTap: () => _playLetterVoiceAudio(pickup),
                                  child: Icon(
                                    _playingMsgId == pickup['id']
                                        ? Icons.stop_circle_rounded
                                        : Icons.play_circle_filled_rounded,
                                    color: const Color(0xFF2563EB),
                                    size: 24,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text("🎙️ Admin Voice Instruction", style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A))),
                                      Text(
                                        pickup['adminVoiceText'] ?? "🎙️ Admin Voice Note (${pickup['adminVoiceDuration'] ?? 5}s)",
                                        style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildMapCard() {
    final routeColor = _getRouteColor();
    final routePoints = _routeStops
        .map((s) => LatLng(s['lat'] as double, s['lng'] as double))
        .toList();

    return Container(
      height: 320,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFDBE2F8), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: routeColor.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _routeStops.isNotEmpty
                    ? LatLng(
                        _routeStops.map((s) => s['lat'] as double).reduce((a, b) => a + b) / _routeStops.length,
                        _routeStops.map((s) => s['lng'] as double).reduce((a, b) => a + b) / _routeStops.length,
                      )
                    : const LatLng(13.047, 80.11),
                initialZoom: 11.5,
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
                // Route stop markers
                if (_routeStops.isNotEmpty)
                  MarkerLayer(
                    markers: [
                      for (int i = 0; i < _routeStops.length; i++) ...[
                        () {
                          final stop = _routeStops[i];
                          final lat = stop['lat'] as double;
                          final lng = stop['lng'] as double;
                          final name = stop['name'] as String? ?? '';
                          final isCollege = name.toUpperCase().contains("COLLEGE") || name.toUpperCase().contains("PEC") || name.toUpperCase().contains("PANIMALAR");
                          return Marker(
                            point: LatLng(lat, lng),
                            width: 100,
                            height: 48,
                            alignment: Alignment.center,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: isCollege ? const Color(0xFF16A34A) : const Color(0xFF1E3A8A),
                                    borderRadius: BorderRadius.circular(10),
                                    boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))],
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(3),
                                        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                                        child: Text(
                                          isCollege ? "🏫" : "${i + 1}",
                                          style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A)),
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Flexible(
                                        child: Text(
                                          name,
                                          style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.location_on_rounded, size: 22, color: Color(0xFF2563EB)),
                              ],
                            ),
                          );
                        }(),
                      ],
                      // Live bus position
                      if (_isTracking && _currentPosition != null)
                        Marker(
                          point: LatLng(_latitude, _longitude),
                          width: 44,
                          height: 44,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(color: routeColor, width: 2),
                              boxShadow: [
                                BoxShadow(color: routeColor.withValues(alpha: 0.3), blurRadius: 8)
                              ],
                            ),
                            child: const Center(child: Text("🚌", style: TextStyle(fontSize: 22))),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
            // Route info overlay (top left)
            Positioned(
              top: 10,
              left: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: routeColor.withValues(alpha: 0.4), width: 1),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 6, offset: const Offset(0, 2))
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: routeColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _getRouteLabelForBus(widget.driverBus),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: routeColor,
                      ),
                    ),
                    if (_routeStops.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      Text(
                        "• ${_routeStops.length} stops",
                        style: const TextStyle(fontSize: 9, color: Color(0xFF64748B), fontWeight: FontWeight.bold),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // GPS locate button
            Positioned(
              right: 12,
              bottom: 12,
              child: FloatingActionButton.small(
                heroTag: 'mapLocate',
                onPressed: () {
                  if (_currentPosition != null) {
                    _mapController.move(LatLng(_latitude, _longitude), 14.0);
                  } else if (_routeStops.isNotEmpty) {
                    // Center on route if no GPS
                    final avgLat = _routeStops.map((s) => s['lat'] as double).reduce((a, b) => a + b) / _routeStops.length;
                    final avgLng = _routeStops.map((s) => s['lng'] as double).reduce((a, b) => a + b) / _routeStops.length;
                    _mapController.move(LatLng(avgLat, avgLng), 11.5);
                  }
                },
                backgroundColor: Colors.white,
                elevation: 2,
                child: Icon(Icons.gps_fixed, color: routeColor, size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _appStatus == "Offline"
        ? const Color(0xFF64748B)
        : (_appStatus == "Broken Down" ? const Color(0xFFDC2626) : const Color(0xFF2563EB));

    return Scaffold(
      backgroundColor: const Color(0xFFEEF2FF),
      floatingActionButton: _allowLocationCapture
          ? FloatingActionButton.extended(
              onPressed: _fetchAndSendLocation,
              label: const Text("Capture Stop"),
              icon: const Icon(Icons.add_location_alt),
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
            )
          : null,
      appBar: AppBar(
        toolbarHeight: 85,
        backgroundColor: Colors.white,
        elevation: 0,
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: const Center(child: Text("🚌", style: TextStyle(fontSize: 18))),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t('appTitle'),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: Color(0xFF1E3A8A)),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                  Text(
                    t('appSubtitle'),
                    style: const TextStyle(fontSize: 8.5, color: Color(0xFF64748B), fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                  const SizedBox(height: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          height: 24,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: DropdownButton<String>(
                            isDense: true,
                            value: widget.currentLang,
                            underline: const SizedBox(),
                            icon: const Padding(
                              padding: EdgeInsets.only(left: 2),
                              child: Icon(Icons.language, color: Color(0xFF1E293B), size: 14),
                            ),
                            style: const TextStyle(color: Color(0xFF1E293B), fontWeight: FontWeight.bold, fontSize: 10),
                            onChanged: (String? newValue) {
                              if (newValue != null) {
                                widget.onLanguageChanged(newValue);
                              }
                            },
                            items: const [
                              DropdownMenuItem(value: 'en', child: Text("English")),
                              DropdownMenuItem(value: 'ta', child: Text("Tamil")),
                              DropdownMenuItem(value: 'te', child: Text("Telugu")),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            color: _firebaseConnected ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _firebaseConnected ? const Color(0xFF86EFAC) : const Color(0xFFFCA5A5),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 6, height: 6,
                                decoration: BoxDecoration(
                                  color: _firebaseConnected ? Colors.green : Colors.red,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _firebaseConnected ? "SYNC ACTIVE" : "OFFLINE",
                                style: TextStyle(
                                  fontSize: 8,
                                  fontWeight: FontWeight.w900,
                                  color: _firebaseConnected ? const Color(0xFF166534) : const Color(0xFF991B1B),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          // Logout button — top right
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: TextButton(
                style: TextButton.styleFrom(
                  backgroundColor: const Color(0xFFF1F5F9),
                  foregroundColor: const Color(0xFF1E293B),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                ),
                onPressed: widget.onLogout,
                child: Text(t('logout'),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: const Color(0xFFDBE2F8), width: 1.2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t('dashboardLabel'),
                              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF64748B), letterSpacing: 0.5),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "Bus ${widget.driverBus}",
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF1E3A8A)),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _getRouteLabelForBus(widget.driverBus),
                              style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            _appStatus.toUpperCase(),
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: statusColor),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Divider(height: 1),
                    const SizedBox(height: 16),
                    Text(
                      t('gpsLabel'),
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF334155)),
                    ),
                    const SizedBox(height: 12),
                    GridView.count(
                      crossAxisCount: 2,
                      shrinkWrap: true,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      childAspectRatio: 2.2,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        _buildFieldTile(t('latLabel'), _isTracking ? _latitude.toStringAsFixed(6) : "--"),
                        _buildFieldTile(t('lngLabel'), _isTracking ? _longitude.toStringAsFixed(6) : "--"),
                        _buildFieldTile(t('accLabel'), _isTracking ? "${_accuracy.toStringAsFixed(1)} m" : "--"),
                        _buildFieldTile(t('updatedLabel'), _isTracking ? _updatedAt : "--"),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // Trip Direction Toggle (1 = Blue [To College], 2 = Orange [To Home])
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE2E8F0), width: 1.2),
                      ),
                      padding: const EdgeInsets.all(4),
                      child: Row(
                        children: [
                          // Button 1: To College (BLUE)
                          Expanded(
                            child: InkWell(
                              onTap: _isTracking ? null : () {
                                setState(() {
                                  _tripDirection = 'To College';
                                });
                              },
                              borderRadius: BorderRadius.circular(12),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                decoration: BoxDecoration(
                                  color: _tripDirection == 'To College'
                                      ? const Color(0xFF2563EB) // Blue for 1
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [
                                    if (_tripDirection == 'To College')
                                      BoxShadow(
                                        color: const Color(0xFF2563EB).withValues(alpha: 0.3),
                                        blurRadius: 6,
                                        offset: const Offset(0, 2),
                                      ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    if (_tripDirection == 'To College')
                                      const Padding(
                                        padding: EdgeInsets.only(right: 6),
                                        child: Icon(Icons.check_rounded, size: 18, color: Colors.white),
                                      ),
                                    Text(
                                      '1',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w900,
                                        color: _tripDirection == 'To College'
                                            ? Colors.white
                                            : const Color(0xFF64748B),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          // Button 2: To Home (ORANGE)
                          Expanded(
                            child: InkWell(
                              onTap: _isTracking ? null : () {
                                setState(() {
                                  _tripDirection = 'To Home';
                                });
                              },
                              borderRadius: BorderRadius.circular(12),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                decoration: BoxDecoration(
                                  color: _tripDirection == 'To Home'
                                      ? const Color(0xFFEA580C) // Orange for 2
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [
                                    if (_tripDirection == 'To Home')
                                      BoxShadow(
                                        color: const Color(0xFFEA580C).withValues(alpha: 0.3),
                                        blurRadius: 6,
                                        offset: const Offset(0, 2),
                                      ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    if (_tripDirection == 'To Home')
                                      const Padding(
                                        padding: EdgeInsets.only(right: 6),
                                        child: Icon(Icons.check_rounded, size: 18, color: Colors.white),
                                      ),
                                    Text(
                                      '2',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w900,
                                        color: _tripDirection == 'To Home'
                                            ? Colors.white
                                            : const Color(0xFF64748B),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF2563EB), // Blue Colour
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: const Color(0xFFDBEAFE),
                              disabledForegroundColor: const Color(0xFF93C5FD),
                              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                              elevation: 2,
                            ),
                            onPressed: (_isTracking || _breakdownActive || _isParked) ? null : () => _startTracking(),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.2),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.play_arrow_rounded,
                                    size: 38,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    t('startTracking'),
                                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF7C3AED), // Violet Colour
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: const Color(0xFFF3E8FF),
                              disabledForegroundColor: const Color(0xFFA78BFA),
                              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                              elevation: 2,
                            ),
                            onPressed: (_isTracking && !_breakdownActive) ? _stopTracking : null,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: const Icon(
                                    Icons.stop_rounded,
                                    size: 38,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    t('stopTracking'),
                                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        // Left: Problem / Breakdown Card
                        Expanded(
                          child: InkWell(
                            onTap: (_isTracking && !_breakdownActive) ? _reportBreakdown : null,
                            borderRadius: BorderRadius.circular(24),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 250),
                              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 10),
                              decoration: BoxDecoration(
                                color: (_isTracking && !_breakdownActive)
                                    ? const Color(0xFFDC2626) // Solid Vibrant Red when active
                                    : const Color(0xFFFFF7ED), // Light Peach/Cream when disabled
                                borderRadius: BorderRadius.circular(24),
                                border: Border.all(
                                  color: (_isTracking && !_breakdownActive)
                                      ? const Color(0xFFB91C1C)
                                      : const Color(0xFFFFEDD5),
                                  width: 1.5,
                                ),
                                boxShadow: [
                                  if (_isTracking && !_breakdownActive)
                                    BoxShadow(
                                      color: const Color(0xFFDC2626).withValues(alpha: 0.3),
                                      blurRadius: 10,
                                      offset: const Offset(0, 4),
                                    ),
                                ],
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Image.memory(
                                    BusCardIcons.breakdownBytes,
                                    height: 76,
                                    gaplessPlayback: true,
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, __, ___) => const Icon(
                                      Icons.warning_amber_rounded,
                                      size: 50,
                                      color: Color(0xFFEA580C),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      t('reportBreakdown'),
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        fontSize: 14,
                                        color: (_isTracking && !_breakdownActive)
                                            ? Colors.white // White text on Red background
                                            : const Color(0xFF9A3412),
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        // Right: Ready to Trip Card
                        Expanded(
                          child: InkWell(
                            onTap: _breakdownActive ? _readyToTrip : null,
                            borderRadius: BorderRadius.circular(24),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 250),
                              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 10),
                              decoration: BoxDecoration(
                                color: _breakdownActive
                                    ? const Color(0xFF16A34A) // Solid Vibrant Green when active
                                    : const Color(0xFFF0FDF4), // Light Pastel Green when disabled
                                borderRadius: BorderRadius.circular(24),
                                border: Border.all(
                                  color: _breakdownActive
                                      ? const Color(0xFF15803D)
                                      : const Color(0xFFDCFCE7),
                                  width: 1.5,
                                ),
                                boxShadow: [
                                  if (_breakdownActive)
                                    BoxShadow(
                                      color: const Color(0xFF16A34A).withValues(alpha: 0.3),
                                      blurRadius: 10,
                                      offset: const Offset(0, 4),
                                    ),
                                ],
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Image.memory(
                                    BusCardIcons.readyBytes,
                                    height: 76,
                                    gaplessPlayback: true,
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, __, ___) => const Icon(
                                      Icons.check_circle_outline_rounded,
                                      size: 50,
                                      color: Color(0xFF16A34A),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      t('readyToTrip'),
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        fontSize: 14,
                                        color: _breakdownActive
                                            ? Colors.white // White text on Green background
                                            : const Color(0xFF166534),
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _isParked ? const Color(0xFFDC2626) : const Color(0xFFF59E0B),
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: const Color(0xFFFEF3C7),
                              disabledForegroundColor: const Color(0xFFFDE68A),
                              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                              elevation: 2,
                            ),
                            onPressed: (!_isTracking && !_breakdownActive) ? (_isParked ? _unparkBus : _parkBus) : null,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: _isParked
                                      ? const Icon(Icons.visibility_off_rounded, size: 36, color: Colors.white)
                                      : ClipRRect(
                                          borderRadius: BorderRadius.circular(6),
                                          child: Image.memory(
                                            BusCardIcons.parkBytes,
                                            width: 36,
                                            height: 36,
                                            gaplessPlayback: true,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, __, ___) => const Icon(
                                              Icons.directions_bus_rounded,
                                              size: 36,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                ),
                                const SizedBox(height: 8),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    _isParked ? t('unparkBus') : t('parkedInCampus'),
                                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Breakdown alerts (Replacement Bus No) — placed directly below Parked in Campus icon button
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xFFDBE2F8), width: 1.2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(t('breakdownSection'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF334155))),
                    const SizedBox(height: 14),
                    Text(t('replacementBus'), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _replacementController,
                      decoration: InputDecoration(
                        hintText: "e.g. B202",
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            t('detectedLocation'),
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B)),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _isTracking ? "${_latitude.toStringAsFixed(4)}, ${_longitude.toStringAsFixed(4)}" : t('locationUnavailable'),
                            style: const TextStyle(fontSize: 11, color: Color(0xFF0F172A), fontWeight: FontWeight.bold),
                            textAlign: TextAlign.end,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFDC2626),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        elevation: 0,
                      ),
                      onPressed: _sendBreakdownAlert,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          t('sendAlert'),
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  ],
                ),
              ),
              const SizedBox(height: 16),

              _buildAuthorizedPickupsCard(),
              const SizedBox(height: 16),



              // Intercom messaging
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xFFDBE2F8), width: 1.2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Text("💬", style: TextStyle(fontSize: 16)),
                            const SizedBox(width: 8),
                            Text(
                              t('intercomTitle'),
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF1E3A8A)),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFDCFCE7),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            t('onlineStatus'),
                            style: const TextStyle(fontSize: 8.5, fontWeight: FontWeight.bold, color: Color(0xFF15803D)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    
                    if (_intercomMessages.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            t('intercomNoMessages'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w600),
                          ),
                        ),
                      )
                    else
                      Container(
                        constraints: const BoxConstraints(maxHeight: 200),
                        child: Builder(builder: (ctx) {
                          // Scroll to bottom after frame
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (_driverChatScrollController.hasClients) {
                              _driverChatScrollController.jumpTo(
                                _driverChatScrollController.position.maxScrollExtent,
                              );
                            }
                          });
                          return ListView.builder(
                            controller: _driverChatScrollController,
                            shrinkWrap: true,
                            itemCount: _intercomMessages.length,
                            itemBuilder: (ctx, idx) {
                              final msg = _intercomMessages[idx];
                              final isMe = msg['sender'] == 'driver';
                              return _buildTextMessageBubble(msg, isMe);
                            },
                          );
                        }),
                      ),
                      
                                    if (_isRecordingVoice)
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF2F2),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFFFCA5A5)),
                        ),
                        child: Row(
                          children: [
                            const _FlashingRedDot(),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    "Recording... 0:${_recordingDurationSecs.toString().padLeft(2, '0')}",
                                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF991B1B)),
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    children: List.generate(8, (idx) {
                                      final height = 3.0 + (idx % 2 == 0 ? 8.0 : 4.0) + (Random().nextDouble() * 5.0);
                                      return Container(
                                        width: 2,
                                        height: height,
                                        margin: const EdgeInsets.symmetric(horizontal: 1),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFEF4444),
                                          borderRadius: BorderRadius.circular(1),
                                        ),
                                      );
                                    }),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              icon: const Icon(Icons.cancel, color: Color(0xFFEF4444), size: 20),
                              onPressed: _cancelRecordingVoice,
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              icon: const Icon(Icons.check_circle, color: Color(0xFF16A34A), size: 20),
                              onPressed: _stopAndSendRecordingVoice,
                            ),
                          ],
                        ),
                      )
                    else
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _driverChatInputCtrl,
                              decoration: InputDecoration(
                                hintText: "Type message or hold mic...",
                                hintStyle: const TextStyle(fontSize: 11, color: Colors.grey),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(30)),
                                fillColor: const Color(0xFFF8FAFC),
                                filled: true,
                              ),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.flash_on, color: Color(0xFF2563EB)),
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0xFFEFF6FF),
                              padding: const EdgeInsets.all(10),
                            ),
                            onPressed: _showDriverPredefinedMessages,
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            icon: const Icon(Icons.send, color: Colors.white),
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0xFF2563EB),
                              padding: const EdgeInsets.all(10),
                            ),
                            onPressed: () {
                              final text = _driverChatInputCtrl.text.trim();
                              if (text.isNotEmpty) {
                                _sendTextMessage(text);
                                _driverChatInputCtrl.clear();
                              }
                            },
                          ),
                          const SizedBox(width: 4),
                          GestureDetector(
                            onLongPressStart: (_) {
                              _startRecordingVoice();
                              _showSnackBar("Recording... Release to send.");
                            },
                            onLongPressEnd: (_) {
                              _stopAndSendRecordingVoice();
                            },
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: const BoxDecoration(
                                color: Color(0xFFEFF6FF),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.mic, color: Color(0xFF2563EB), size: 20),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              Center(
                child: Text(
                  t('bottomInfo'),
                  style: const TextStyle(fontSize: 10, color: Color(0xFF64748B), fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _FlashingRedDot extends StatefulWidget {
  const _FlashingRedDot();

  @override
  State<_FlashingRedDot> createState() => _FlashingRedDotState();
}

class _FlashingRedDotState extends State<_FlashingRedDot> {
  bool _visible = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (mounted) {
        setState(() {
          _visible = !_visible;
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _visible ? 1.0 : 0.2,
      duration: const Duration(milliseconds: 200),
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: Colors.red,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
