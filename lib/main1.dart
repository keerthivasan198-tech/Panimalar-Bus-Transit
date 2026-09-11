import 'dart:async';
import 'dart:convert';
import 'screens/student/qr_scanner_screen.dart';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'config/routes_config.dart';

class CampusPoint {
  final String name;
  final String icon;
  final LatLng coords;
  CampusPoint({required this.name, required this.icon, required this.coords});
}

final List<CampusPoint> campusPoints = [
  CampusPoint(name:"Main Entrance Gate",     icon:"🚪", coords: const LatLng(13.047233247170958, 80.07553083848039)),
  CampusPoint(name:"Admin / Admission Block",icon:"🏢", coords: const LatLng(13.048850145300088, 80.07540895317958)),
  CampusPoint(name:"CSE Department",         icon:"💻", coords: const LatLng(13.049685242260539, 80.07532862941522)),
  CampusPoint(name:"AIDS (AI & Data Sci.)",  icon:"🤖", coords: const LatLng(13.049806482709092, 80.0764615955046)),
  CampusPoint(name:"ECE Department",         icon:"📡", coords: const LatLng(13.05087255939414,  80.07525881054877)),
  CampusPoint(name:"EEE Department",         icon:"⚡", coords: const LatLng(13.054592294968348, 80.07269418103328)),
  CampusPoint(name:"IT Department",          icon:"🖥️", coords: const LatLng(13.053480247199628, 80.07339790715875)),
  CampusPoint(name:"CSBS Department",        icon:"💼", coords: const LatLng(13.051718101355666, 80.07600489209125)),
  CampusPoint(name:"Mechanical Dept.",       icon:"🔧", coords: const LatLng(13.054738616658025, 80.07274023151132)),
  CampusPoint(name:"MBA Block",              icon:"📊", coords: const LatLng(13.05391294313128,  80.07533907315717)),
  CampusPoint(name:"Mess 1 (Main Mess)",     icon:"🍛›", coords: const LatLng(13.050841204263154, 80.07473998885077)),
  CampusPoint(name:"Mess 2 (Hostel Mess)",   icon:"🍛", coords: const LatLng(13.053515782730686, 80.07514570981196))
];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: "AIzaSyBUozEQcU48yRBSSM3EquhV8Sm1vWtRPFY",
        appId: "1:538185362536:web:e8d35e63d4c641979c1fdd",
        messagingSenderId: "538185362536",
        projectId: "gen-lang-client-0636615491",
        databaseURL: "https://gen-lang-client-0636615491-default-rtdb.asia-southeast1.firebasedatabase.app",
      ),
    );
    await FirebaseAuth.instance.signInAnonymously();
  } catch (e) {
    debugPrint("Firebase initialization or auth error: $e");
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Panimalar Smart Transit',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          primary: const Color(0xFF2563EB),
          secondary: const Color(0xFF16A34A),
          surface: Colors.white,
        ),
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        fontFamily: 'Plus Jakarta Sans',
      ),
      home: const RootShell(),
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  String _role = "loading";

  @override
  void initState() {
    super.initState();
    _loadRole();
  }

  Future<void> _loadRole() async {
    final prefs = await SharedPreferences.getInstance();
    final savedRole = prefs.getString("user_role") ?? "none";
    setState(() {
      _role = savedRole;
    });
  }

  void _updateRole(String role) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("user_role", role);
    setState(() {
      _role = role;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_role == "loading") {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    } else if (_role == "driver") {
      return DriverShell(onSwitchRole: () => _updateRole("none"));
    } else if (_role == "student") {
      return MainShell(onSwitchRole: () => _updateRole("none"));
    } else {
      return RoleSelectionScreen(
        onSelectRole: (role) {
          _updateRole(role);
        },
      );
    }
  }
}

class MainShell extends StatefulWidget {
  final VoidCallback onSwitchRole;
  const MainShell({super.key, required this.onSwitchRole});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  // Firebase Live tracking variables
  bool _busIsOnline = false;
  double? _busLat;
  double? _busLng;
  double? _busAccuracy;
  String _busUpdatedAt = "--:--";
  String _busStatus = "offline";
  
  // Lerped render positions for smooth map marker movement
  double? _renderLat;
  double? _renderLng;
  Timer? _lerpTimer;

  // Shared preferences state
  String _savedStop = "";
  String get _formattedSavedStop => _savedStop.replaceAll(RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)'), '').trim();
  String _studentName = "Student Name";
  String _studentYear = "3rd Year";
  String _studentDept = "Computer Science (CSE)";

  // Alert tracking state
  bool _hasAlertedApproaching = false;
  bool _hasAlertedArrived = false;
  bool _wasBusOnline = false; // tracks previous online state for bus-ready detection

  // In-app notification state
  bool _showNotification = false;
  String _notifTitle = "";
  String _notifBody = "";
  String _notifIcon = "";
  double _notifProgress = 1.0;
  Timer? _notifTimer;
  Timer? _notifProgressTimer;

  bool _breakdownActive = false;
  String _replacementBus = "";
  StreamSubscription? _breakdownSub;
  StreamSubscription? _announcementSub;
  StreamSubscription? _routesSub;
  StreamSubscription? _stopLocationsSub;
  String? _activeAnnouncement;
  String? _activeAnnouncementBase64;
  String? _activeAnnouncementType;

  String _busFirebaseId = 'BUS101';

  // Bus perfectly routed points
  List<LatLng> _busRoutePoints = [];
  bool _busRouteLoading = false;

  final List<String> _routeStops = [
    "Porur Junction",
    "Iyyapanthagal",
    "Durgai Amman Kovil Stop",
    "Katupakam Auto Busstand",
    "Katupakam",
    "Paradise Stop",
    "Munishvaran Kovil Stop",
    "Dmart",
    "Aravind Eye Hospital",
    "Senneer Kuppam",
    "Panimalar Engineering College"
  ];

  final Map<String, LatLng> _coords = {
    ...coordsConfig,
    "Porur Junction":             const LatLng(13.037736, 80.135552),
    "Iyyapanthagal":              const LatLng(13.039030, 80.132648),
    "Durgai Amman Kovil Stop":    const LatLng(13.040857, 80.127750),
    "Katupakam Auto Busstand":    const LatLng(13.042522, 80.123933),
    "Katupakam":                  const LatLng(13.047330, 80.119765),
    "Paradise Stop":              const LatLng(13.047913, 80.120151),
    "Munishvaran Kovil Stop":     const LatLng(13.050300, 80.121800),
    "Dmart":                      const LatLng(13.052175, 80.122919),
    "Aravind Eye Hospital":       const LatLng(13.053110, 80.123690),
    "Senneer Kuppam":             const LatLng(13.056702, 80.113804),
    "Panimalar Engineering College": const LatLng(13.047076, 80.075582)
  };

  LatLng? _getStopCoord(String stopName) {
    if (_coords.containsKey(stopName)) return _coords[stopName];
    final cleanName = stopName.replaceAll(RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)'), '').trim();
    if (_coords.containsKey(cleanName)) return _coords[cleanName];
    final cleanKey = cleanName.toLowerCase();
    if (_coords.containsKey(cleanKey)) return _coords[cleanKey];

    final coordMatch = RegExp(r'\((?:Lat:\s*)?([-\d.]+)[,\s]+(?:Lng:\s*)?([-\d.]+)\)').firstMatch(stopName);
    if (coordMatch != null) {
      try {
        final lat = double.parse(coordMatch.group(1)!);
        final lng = double.parse(coordMatch.group(2)!);
        return LatLng(lat, lng);
      } catch (_) {}
    }
    return coordsConfig[cleanName] ?? coordsConfig[stopName];
  }

  @override
  void initState() {
    super.initState();
    _loadPreferences();
    _startFirebaseListener();
    _startLerpLoop();
    _fetchBusOsrmRoute();
  }

  Future<void> _fetchBusOsrmRoute() async {
    if (_routeStops.length < 2) {
      setState(() => _busRoutePoints = []);
      return;
    }
    if (!mounted) return;
    setState(() => _busRouteLoading = true);

    try {
      final coordsList = <String>[];
      for (var stop in _routeStops) {
        final coord = _getStopCoord(stop);
        if (coord != null) {
          coordsList.add('${coord.longitude.toStringAsFixed(6)},${coord.latitude.toStringAsFixed(6)}');
        }
      }

      if (coordsList.length < 2) {
        setState(() => _busRouteLoading = false);
        return;
      }

      final coords = coordsList.join(';');
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
                _busRoutePoints = points;
                _busRouteLoading = false;
              });
            }
            return;
          }
        }
      }
    } catch (e) {
      debugPrint('OSRM bus route fetch error: $e');
    }

    if (mounted) {
      setState(() {
        _busRoutePoints = _routeStops.map((s) => _getStopCoord(s)).whereType<LatLng>().toList();
        _busRouteLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _lerpTimer?.cancel();
    _notifTimer?.cancel();
    _notifProgressTimer?.cancel();
    _breakdownSub?.cancel();
    _announcementSub?.cancel();
    _routesSub?.cancel();
    _stopLocationsSub?.cancel();
    super.dispose();
  }

  void _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _savedStop = prefs.getString("savedStop") ?? "";
      _studentName = prefs.getString("studentName") ?? "Student Name";
      _studentYear = prefs.getString("studentYear") ?? "3rd Year";
      _studentDept = prefs.getString("studentDept") ?? "Computer Science (CSE)";
    });
  }

  void _saveStop(String stopName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("savedStop", stopName);
    setState(() {
      _savedStop = stopName;
      _hasAlertedApproaching = false;
      _hasAlertedArrived = false;
    });
    _showSnackBar("â­ Boarding stop saved: $stopName");
  }

  void _saveProfile(String name, String year, String dept) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("studentName", name);
    await prefs.setString("studentYear", year);
    await prefs.setString("studentDept", dept);
    setState(() {
      _studentName = name;
      _studentYear = year;
      _studentDept = dept;
    });
    _showSnackBar("✅ Profile saved successfully");
  }

  void _startFirebaseListener() {
    if (Firebase.apps.isEmpty) {
      debugPrint("Firebase not initialized, skipping database listener.");
      return;
    }
    try {
      bool isInitialSnapshot = true;
      FirebaseDatabase.instance.ref('liveLocations/$_busFirebaseId').onValue.listen((event) {
        final data = event.snapshot.value as Map?;
        final isOnline = data != null && data['status'] != 'offline' && data['status'] != 'completed';

        if (isInitialSnapshot) {
          isInitialSnapshot = false;
          if (mounted) {
            setState(() {
              _busIsOnline = isOnline;
              _wasBusOnline = isOnline;
              _busStatus = isOnline ? (data?['status'] as String? ?? "tracking") : "offline";
              if (isOnline && data != null) {
                _busLat = (data['lat'] as num).toDouble();
                _busLng = (data['lng'] as num).toDouble();
                _busAccuracy = (data['acc'] as num?)?.toDouble() ?? (data['accuracy'] as num?)?.toDouble() ?? 10.0;
              }
            });
          }
          return;
        }

        if (data == null || !isOnline) {
          setState(() {
            _wasBusOnline = false;
            _busIsOnline = false;
            _busStatus = "offline";
          });
          return;
        }

        final bool justCameOnline = !_wasBusOnline && isOnline;

        setState(() {
          _busIsOnline = true;
          _wasBusOnline = true;
          _busLat = (data['lat'] as num).toDouble();
          _busLng = (data['lng'] as num).toDouble();
          _busAccuracy = (data['acc'] as num?)?.toDouble() ?? (data['accuracy'] as num?)?.toDouble() ?? 10.0;
          _busStatus = data['status'] as String? ?? "tracking";
          
          final rawUpdatedAt = data['updatedAt'] as String?;
          if (rawUpdatedAt != null) {
            try {
              final dt = DateTime.parse(rawUpdatedAt).toLocal();
              _busUpdatedAt = "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
            } catch (_) {
              _busUpdatedAt = "--:--";
            }
          } else {
            _busUpdatedAt = "--:--";
          }

          if (_renderLat == null || _renderLng == null) {
            _renderLat = _busLat;
            _renderLng = _busLng;
          }
        });

        // Show bus-ready banner when bus first comes online
        if (justCameOnline) {
          _showInAppNotification(
            "🚌 Bus 138 is Ready!",
            "The bus has started its route. Live GPS tracking is now active. Get ready to board!",
            "✅",
            durationMs: 10000,
          );
        }

        // Proximity Alert checks
        if (_savedStop.isNotEmpty && _busLat != null && _busLng != null) {
          final myStopIdx = _routeStops.indexOf(_savedStop);
          final nearestIdx = _getNearestStopIndex(_busLat!, _busLng!);
          
          if (nearestIdx == 0) {
            _hasAlertedApproaching = false;
            _hasAlertedArrived = false;
          }

          if (myStopIdx != -1) {
            if (nearestIdx == myStopIdx - 1 && !_hasAlertedApproaching) {
              _hasAlertedApproaching = true;
              _showInAppNotification(
                "Bus 138 is approaching!",
                "Bus 138 is at ${_routeStops[nearestIdx]}, which is 1 stop away from $_savedStop.",
                "🔔",
              );
            } else if (nearestIdx == myStopIdx && !_hasAlertedArrived) {
              _hasAlertedArrived = true;
              _showInAppNotification(
                "Bus 138 has arrived!",
                "Bus 138 is now at your boarding stop: $_savedStop. Get ready to board!",
                "ðŸš",
              );
            }
          }
        }
      }, onError: (e) {
        debugPrint("Database listen error: $e");
      });

      _breakdownSub = FirebaseDatabase.instance.ref('breakdowns/$_busFirebaseId').onValue.listen((event) {
        final data = event.snapshot.value as Map?;
        if (data == null) {
          setState(() {
            _breakdownActive = false;
            _replacementBus = "";
          });
          return;
        }
        setState(() {
          _breakdownActive = true;
          _replacementBus = data['replacement'] as String? ?? "Unknown";
        });
      }, onError: (e) {
        debugPrint("Breakdown database listen error: $e");
      });

      _announcementSub = FirebaseDatabase.instance.ref('announcements/active').onValue.listen((event) {
        final data = event.snapshot.value as Map?;
        if (data != null && data['message'] != null) {
          setState(() {
            final titleStr = data['title'] != null ? "${data['title']} : " : "";
            final attachStr = data['attachmentBase64'] != null ? "  📎 Tap to view" : "";
            _activeAnnouncement = "$titleStr${data['message']}$attachStr";
            _activeAnnouncementBase64 = data['attachmentBase64'];
            _activeAnnouncementType = data['attachmentType'];
          });
        } else {
          setState(() {
            _activeAnnouncement = null;
            _activeAnnouncementBase64 = null;
            _activeAnnouncementType = null;
          });
        }
      });

      _stopLocationsSub = FirebaseDatabase.instance.ref('stopLocations').onValue.listen((event) {
        if (event.snapshot.exists && event.snapshot.value != null) {
          final data = event.snapshot.value;
          if (data is Map) {
            data.forEach((key, val) {
              if (val is Map) {
                final lat = (val['lat'] as num?)?.toDouble();
                final lng = (val['lng'] as num?)?.toDouble();
                if (lat != null && lng != null) {
                  _coords[key.toString()] = LatLng(lat, lng);
                  _coords[key.toString().toLowerCase()] = LatLng(lat, lng);
                }
              }
            });
            if (mounted) setState(() {});
          }
        }
      });

      _routesSub = FirebaseDatabase.instance.ref('routes').onValue.listen((event) {
        if (event.snapshot.exists && event.snapshot.value != null) {
          final data = event.snapshot.value;
          List<Map<String, dynamic>> allRoutes = [];
          if (data is Map) {
            data.forEach((k, v) {
              if (v is Map) {
                allRoutes.add(Map<String, dynamic>.from(v));
              }
            });
          } else if (data is List) {
            for (var item in data) {
              if (item != null && item is Map) {
                allRoutes.add(Map<String, dynamic>.from(item));
              }
            }
          }

          // Find route for this bus or matching active route
          Map<String, dynamic>? matchingRoute;
          final busClean = _busFirebaseId.replaceAll(RegExp(r'[^0-9]'), '');
          for (var r in allRoutes) {
            if (r['deleted'] == true || r['isDeleted'] == true || r['status'] == 'deleted') continue;
            final rKey = r['key']?.toString().toLowerCase() ?? '';
            final rName = r['name']?.toString().toLowerCase() ?? '';
            if ((busClean.isNotEmpty && (rKey.contains(busClean) || rName.contains(busClean))) ||
                rKey.contains(_busFirebaseId.toLowerCase())) {
              matchingRoute = r;
              break;
            }
          }
          matchingRoute ??= allRoutes.firstWhere(
            (r) => r['deleted'] != true && r['isDeleted'] != true && r['status'] != 'deleted' && (r['stops'] as List?)?.isNotEmpty == true,
            orElse: () => {},
          );

          if (matchingRoute.isNotEmpty && matchingRoute['stops'] is List) {
            final List rawStops = matchingRoute['stops'] as List;
            final List<String> loadedStops = [];
            for (var s in rawStops) {
              if (s != null && s.toString().trim().isNotEmpty) {
                final sStr = s.toString().trim();
                loadedStops.add(sStr);
                final coordMatch = RegExp(r'\((?:Lat:\s*)?([-\d.]+)[,\s]+(?:Lng:\s*)?([-\d.]+)\)').firstMatch(sStr);
                if (coordMatch != null) {
                  try {
                    final lat = double.parse(coordMatch.group(1)!);
                    final lng = double.parse(coordMatch.group(2)!);
                    _coords[sStr] = LatLng(lat, lng);
                    final cleanName = sStr.replaceAll(RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)'), '').trim();
                    _coords[cleanName] = LatLng(lat, lng);
                    _coords[cleanName.toLowerCase()] = LatLng(lat, lng);
                  } catch (_) {}
                }
              }
            }

            if (loadedStops.isNotEmpty && mounted) {
              setState(() {
                _routeStops.clear();
                _routeStops.addAll(loadedStops);
              });
              _fetchBusOsrmRoute();
            }
          }
        }
      });
    } catch (e) {
      debugPrint("Error starting database listener: $e");
    }
  }

  void _showInAppNotification(String title, String body, String icon, {int durationMs = 5000}) {
    _notifTimer?.cancel();
    _notifProgressTimer?.cancel();

    HapticFeedback.vibrate();

    setState(() {
      _notifTitle = title;
      _notifBody = body;
      _notifIcon = icon;
      _showNotification = true;
      _notifProgress = 1.0;
    });

    final duration = Duration(milliseconds: durationMs);
    const steps = 100;
    final stepDuration = Duration(milliseconds: durationMs ~/ steps);
    
    int currentStep = 0;
    _notifProgressTimer = Timer.periodic(stepDuration, (timer) {
      currentStep++;
      if (currentStep >= steps) {
        timer.cancel();
      } else {
        setState(() {
          _notifProgress = 1.0 - (currentStep / steps);
        });
      }
    });

    _notifTimer = Timer(duration, () {
      if (mounted) {
        setState(() {
          _showNotification = false;
        });
      }
    });
  }

  void _startLerpLoop() {
    _lerpTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (_busLat == null || _busLng == null || _renderLat == null || _renderLng == null) return;
      const lerpSpeed = 0.08;
      setState(() {
        _renderLat = _renderLat! + (_busLat! - _renderLat!) * lerpSpeed;
        _renderLng = _renderLng! + (_busLng! - _renderLng!) * lerpSpeed;
      });
    });
  }

  double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLon = (lon2 - lon1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * sin(dLon / 2) * sin(dLon / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  int _getNearestStopIndex(double lat, double lng) {
    int idx = 0;
    double minD = double.infinity;
    for (int i = 0; i < _routeStops.length; i++) {
      final stopName = _routeStops[i];
      final stopCoord = _getStopCoord(stopName);
      if (stopCoord == null) continue;
      final d = _haversineKm(lat, lng, stopCoord.latitude, stopCoord.longitude);
      if (d < minD) {
        minD = d;
        idx = i;
      }
    }
    return idx;
  }

  int? _calculateEtaMinutes(int nearestIdx) {
    if (!_busIsOnline || _busLat == null || _busLng == null || _savedStop.isEmpty) return null;
    final myStopIdx = _routeStops.indexWhere((s) => s == _savedStop || s.replaceAll(RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)'), '').trim() == _formattedSavedStop);
    if (myStopIdx == -1 || nearestIdx > myStopIdx) return null;

    double totalDist = 0.0;
    double currentLat = _busLat!;
    double currentLng = _busLng!;

    for (int i = nearestIdx; i <= myStopIdx; i++) {
      final stopName = _routeStops[i];
      final stopCoord = _getStopCoord(stopName);
      if (stopCoord != null) {
        totalDist += _haversineKm(currentLat, currentLng, stopCoord.latitude, stopCoord.longitude);
        currentLat = stopCoord.latitude;
        currentLng = stopCoord.longitude;
      }
    }

    final intermediateStops = myStopIdx - nearestIdx;
    int eta = (totalDist * 2.5 + intermediateStops).round();
    return eta < 1 ? 1 : eta;
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold)),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: const Color(0xFF2563EB),
      ),
    );
  }

  Widget _buildFirebaseStatusStrip() {
    Color bgColor;
    Color textColor;
    String statusText;
    
    if (_busIsOnline) {
      bgColor = const Color(0xFFF0FDF4);
      textColor = const Color(0xFF15803D);
      statusText = "Firebase connected — live GPS data";
    } else if (_busStatus == "offline") {
      bgColor = const Color(0xFFFEF2F2);
      textColor = const Color(0xFFDC2626);
      statusText = "Bus 138 GPS offline — driver not tracking";
    } else {
      bgColor = const Color(0xFFFEFCE8);
      textColor = const Color(0xFF92400E);
      statusText = "Connecting to Firebase…";
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      decoration: BoxDecoration(
        color: bgColor,
        border: const Border(bottom: BorderSide(color: Color(0xFFE8EDF8))),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: textColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              statusText,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
            ),
          ),
          Text(
            _busUpdatedAt,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: textColor.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGlobalMyStopBanner() {
    final int nearestIdx = (_busLat != null && _busLng != null) ? _getNearestStopIndex(_busLat!, _busLng!) : 0;
    final int? eta = _calculateEtaMinutes(nearestIdx);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1E40AF), Color(0xFF2563EB)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  "ðŸ“ MY STOP",
                  style: TextStyle(
                    fontSize: 9,
                    color: Color(0xFF93C5FD),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _formattedSavedStop,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _savedStop = "";
                    });
                    SharedPreferences.getInstance().then((prefs) {
                      prefs.setString("savedStop", "");
                    });
                    _showSnackBar("â­ Boarding stop cleared");
                  },
                  child: const Text(
                    "Change stop",
                    style: TextStyle(
                      fontSize: 11,
                      color: Color(0xFF93C5FD),
                      decoration: TextDecoration.underline,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _busIsOnline ? (eta != null ? "$eta" : "Passed") : "—",
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  height: 1,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _busIsOnline ? (eta != null ? "min away" : "") : "offline",
                style: const TextStyle(
                  fontSize: 10,
                  color: Color(0xFF93C5FD),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInAppNotificationWidget() {
    return Material(
      color: Colors.transparent,
      elevation: 8,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFE8EDF8)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _notifIcon,
                  style: const TextStyle(fontSize: 28),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "PANIMALAR TRANSIT — BUS 138",
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF64748B),
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _notifTitle,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _notifBody,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF64748B),
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                height: 3,
                child: LinearProgressIndicator(
                  value: _notifProgress,
                  backgroundColor: const Color(0xFFF1F5F9),
                  valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF2563EB)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = [
      _buildHomeTab(),
      _buildTrackTab(),
      _buildCampusNavTab(),
      _buildProfileTab(),
    ];

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const QRScannerScreen(),
            ),
          );
        },
        backgroundColor: const Color(0xFF2563EB),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Scan Bus Pass', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
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
                color: Colors.white,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: const Icon(
                Icons.directions_bus_rounded,
                color: Color(0xFF2563EB),
                size: 22,
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  "Panimalar Transit",
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: _busIsOnline ? const Color(0xFF22C55E) : const Color(0xFFEF4444),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _busIsOnline ? "Live GPS Active" : "GPS Connection Offline",
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: _busIsOnline ? const Color(0xFF16A34A) : const Color(0xFFEF4444),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => StudentBreakdownNotificationsPage(
                    breakdownActive: _breakdownActive,
                    busId: _busFirebaseId,
                    replacement: _replacementBus,
                  ),
                ),
              );
            },
            icon: Stack(
              children: [
                const Icon(
                  Icons.notifications_none_rounded,
                  color: Color(0xFF475569),
                  size: 24,
                ),
                if (_breakdownActive)
                  Positioned(
                    right: 2,
                    top: 2,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16.0, left: 4),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: _busIsOnline ? const Color(0xFFE8F5E9) : const Color(0xFFFFEBEE),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: _busIsOnline ? const Color(0xFF2E7D32) : const Color(0xFFC62828),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _busIsOnline ? "LIVE" : "OFFLINE",
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        color: _busIsOnline ? const Color(0xFF2E7D32) : const Color(0xFFC62828),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildFirebaseStatusStrip(),
              MarqueeNoticeBar(
                text: _activeAnnouncement ?? "🚌 Bus No 138 — Porur Junction → Panimalar Engineering College · Live GPS Tracking Active",
                onTap: _activeAnnouncementBase64 != null ? () {
                  showDialog(
                    context: context,
                    builder: (c) => AlertDialog(
                      contentPadding: EdgeInsets.zero,
                      content: Image.memory(base64Decode(_activeAnnouncementBase64!), fit: BoxFit.contain),
                      actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text('Close'))]
                    ),
                  );
                } : null,
              ),
              if (_currentIndex != 1 && _savedStop.isNotEmpty)
                _buildGlobalMyStopBanner(),
              Expanded(
                child: pages[_currentIndex],
              ),
            ],
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 400),
            curve: Curves.fastOutSlowIn,
            top: _showNotification ? 16 : -180,
            left: 16,
            right: 16,
            child: _buildInAppNotificationWidget(),
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        type: BottomNavigationBarType.fixed,
        backgroundColor: Colors.white,
        selectedItemColor: const Color(0xFF2563EB),
        unselectedItemColor: const Color(0xFF94A3B8),
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 11),
        unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home_outlined), activeIcon: Icon(Icons.home), label: "Home"),
          BottomNavigationBarItem(icon: Icon(Icons.location_on_outlined), activeIcon: Icon(Icons.location_on), label: "Live"),
          BottomNavigationBarItem(icon: Icon(Icons.map_outlined), activeIcon: Icon(Icons.map), label: "Campus"),
          BottomNavigationBarItem(icon: Icon(Icons.person_outline), activeIcon: Icon(Icons.person), label: "Profile"),
        ],
      ),
    );
  }

  Widget _buildHomeTab() {
    final int nearestIdx = (_busLat != null && _busLng != null)
        ? _getNearestStopIndex(_busLat!, _busLng!)
        : 0;
    final int? eta = _calculateEtaMinutes(nearestIdx);

    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── HERO BANNER with real bus photo ─────────────────────────
          _buildHeroBanner(),

          // ── Body content ────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Greeting
                Text(
                  _getTimeGreeting(),
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF94A3B8),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _studentName,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 20),

                // Bus status card
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _busIsOnline
                          ? const Color(0xFFBBF7D0)
                          : const Color(0xFFE2E8F0),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.04),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: _busIsOnline
                              ? const Color(0xFFDCFCE7)
                              : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Icon(
                          Icons.directions_bus_rounded,
                          color: _busIsOnline
                              ? const Color(0xFF16A34A)
                              : const Color(0xFF94A3B8),
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _busIsOnline
                                  ? "Bus 138 is on route"
                                  : "Bus 138 is offline",
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: _busIsOnline
                                    ? const Color(0xFF16A34A)
                                    : const Color(0xFF64748B),
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              _busIsOnline
                                  ? "Live GPS • Updated $_busUpdatedAt"
                                  : "Driver has not started tracking yet",
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF94A3B8)),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: _busIsOnline
                              ? const Color(0xFF22C55E)
                              : const Color(0xFFCBD5E1),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                
                // Scan QR to Board Button
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(50),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    elevation: 0,
                  ),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const QRScannerScreen(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.qr_code_scanner, size: 20),
                  label: const Text('Scan Bus QR to Board', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                ),
                const SizedBox(height: 12),

                // Set boarding stop / ETA card
                if (_savedStop.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFDBEAFE)),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF2563EB).withValues(alpha: 0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: const Color(0xFFEFF6FF),
                            borderRadius: BorderRadius.circular(13),
                          ),
                          child: const Icon(
                            Icons.my_location_rounded,
                            color: Color(0xFF2563EB),
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                "MY BOARDING STOP",
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF94A3B8),
                                  letterSpacing: 0.5,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _formattedSavedStop,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1E293B),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              GestureDetector(
                                onTap: () {
                                  setState(() => _savedStop = "");
                                  SharedPreferences.getInstance()
                                      .then((p) => p.setString("savedStop", ""));
                                },
                                child: const Text(
                                  "Change stop",
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF2563EB),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              _busIsOnline
                                  ? (eta != null ? "$eta" : "🏁")
                                  : "—",
                              style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w900,
                                  color: _busIsOnline ? const Color(0xFF2563EB) : const Color(0xFF94A3B8)),
                            ),
                            Text(
                              _busIsOnline
                                  ? (eta != null ? "min away" : "Passed")
                                  : "offline",
                              style: const TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF94A3B8),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  GestureDetector(
                    onTap: () => setState(() => _currentIndex = 1),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.03),
                            blurRadius: 10,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: const Color(0xFFEFF6FF),
                              borderRadius: BorderRadius.circular(13),
                            ),
                            child: const Icon(
                              Icons.location_on_outlined,
                              color: Color(0xFF2563EB),
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 14),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "Set your boarding stop",
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF1E293B),
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  "Get ETA alerts when bus is near",
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF94A3B8),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(
                            Icons.arrow_forward_ios_rounded,
                            size: 13,
                            color: Color(0xFF94A3B8),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),

                // Quick Actions
                const Text(
                  "Quick Actions",
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF64748B),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _buildActionTile(
                        icon: Icons.location_on_rounded,
                        iconColor: const Color(0xFF2563EB),
                        label: "Track Live",
                        onTap: () => setState(() => _currentIndex = 1),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildActionTile(
                        icon: Icons.map_outlined,
                        iconColor: const Color(0xFF475569),
                        label: "Campus Map",
                        onTap: () => setState(() => _currentIndex = 2),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Route
                const Text(
                  "Route",
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF64748B),
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.03),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      for (int i = 0; i < _routeStops.length; i++) ...[
                        _buildStopRow(
                          _routeStops[i].replaceAll(RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)'), '').trim(),
                          isFirst: i == 0,
                          isLast: i == _routeStops.length - 1,
                          isMyStop: _routeStops[i] == _savedStop || _routeStops[i].replaceAll(RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)'), '').trim() == _formattedSavedStop,
                        ),
                        if (i < _routeStops.length - 1)
                          _buildStopConnector(),
                      ]
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Center(
                  child: Text(
                    "Showing all ${_routeStops.length} stops in sequence",
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF94A3B8),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      height: 175,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2563EB).withValues(alpha: 0.25),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Stack(
          children: [
            // Full horizontal bus photo as card background
            Positioned.fill(
              child: Image.asset(
                'assets/images/panimalar_bus.png',
                fit: BoxFit.cover,
                alignment: Alignment.center,
              ),
            ),

            // Gradient overlay to blend image and ensure text readability
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF1E40AF).withValues(alpha: 0.92),
                      const Color(0xFF2563EB).withValues(alpha: 0.75),
                      const Color(0xFF3B82F6).withValues(alpha: 0.25),
                    ],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                ),
              ),
            ),

            // Text content ── left side
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Bus number tag
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      "BUS 138",
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Heading + Live badge
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        "Bus 138 is on the way",
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (_busIsOnline)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF22C55E),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.circle, size: 5, color: Colors.white),
                              SizedBox(width: 4),
                              Text(
                                "Live",
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    "The bus has started its route.\nLive GPS tracking is now active.",
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white70,
                      height: 1.4,
                    ),
                  ),
                  const Spacer(),

                  // Updated pill
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.location_on, size: 12, color: Color(0xFF2563EB)),
                        const SizedBox(width: 4),
                        Text(
                          "Updated $_busUpdatedAt",
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1E293B),
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
    );
  }

  String _getTimeGreeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return "Good morning ☀️";
    if (hour < 17) return "Good afternoon 🌤️";
    return "Good evening 🌙";
  }

  Widget _buildActionTile({
    required IconData icon,
    required Color iconColor,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE2E8F0)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: iconColor,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1E293B),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStopRow(String name,
      {bool isFirst = false, bool isLast = false, bool isMyStop = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Center(
              child: Container(
                width: isFirst || isLast ? 10 : 8,
                height: isFirst || isLast ? 10 : 8,
                decoration: BoxDecoration(
                  color: isFirst || isLast || isMyStop
                      ? const Color(0xFF2563EB)
                      : Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isFirst || isLast || isMyStop
                        ? const Color(0xFF2563EB)
                        : const Color(0xFFCBD5E1),
                    width: 1.5,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isFirst || isLast || isMyStop
                    ? FontWeight.w700
                    : FontWeight.w400,
                color: isMyStop
                    ? const Color(0xFF2563EB)
                    : const Color(0xFF334155),
              ),
            ),
          ),
          if (isFirst)
            const Text("Start",
                style: TextStyle(fontSize: 11, color: Color(0xFF2563EB), fontWeight: FontWeight.w700)),
          if (isLast)
            const Text("End",
                style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8), fontWeight: FontWeight.w600)),
          if (isMyStop)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                "My stop",
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF2563EB)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStopConnector() {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Container(
        width: 1.5,
        height: 16,
        color: const Color(0xFFE2E8F0),
      ),
    );
  }


  Widget _buildTrackTab() {
    if (_savedStop.isEmpty) {
      return _buildStopSelectionScreen();
    } else {
      return _buildLiveTrackingScreen();
    }
  }

  Widget _buildStopSelectionScreen() {
    String? tempStop = _savedStop.isEmpty ? null : _savedStop;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(16.0),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1E40AF), Color(0xFF2563EB)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("🚌 ${_busFirebaseId.replaceAll(RegExp(r'^[Bb]us\s*|^[Bb]'), '')}", style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: Colors.white)),
                const SizedBox(height: 4),
                Text(
                  _routeStops.isNotEmpty 
                      ? "${_routeStops.first.replaceAll(RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)'), '').trim()} → ${_routeStops.last.replaceAll(RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)'), '').trim()}"
                      : "Panimalar Campus Transit Route",
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white)
                ),
                const SizedBox(height: 8),
                Text(
                  "🏫 Terminus: ${_routeStops.isNotEmpty ? _routeStops.last.replaceAll(RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)'), '').trim() : 'Panimalar Engineering College'}",
                  style: const TextStyle(fontSize: 11, color: Color(0xFFBFDBFE), fontWeight: FontWeight.bold)
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          Container(
            padding: const EdgeInsets.all(16.0),
            decoration: BoxDecoration(
              color: const Color(0xFFFEFCE8),
              border: Border.all(color: const Color(0xFFFDE68A), width: 1.5),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Text("🔔", style: TextStyle(fontSize: 16)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Alert me when Bus ${_busFirebaseId.replaceAll(RegExp(r'^[Bb]us\s*|^[Bb]'), '')} approaches my stop",
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF92400E),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: tempStop,
                  hint: const Text("Select boarding stop", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  decoration: InputDecoration(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(30),
                      borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(30),
                      borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(30),
                      borderSide: const BorderSide(color: Color(0xFF2563EB)),
                    ),
                  ),
                  style: const TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 13),
                  items: (_routeStops.length > 1 ? _routeStops.sublist(0, _routeStops.length - 1) : _routeStops).map((stop) {
                    return DropdownMenuItem<String>(
                      value: stop,
                      child: Text(stop.replaceAll(RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)'), '').trim()),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      tempStop = val;
                      _saveStop(val);
                    }
                  },
                ),
                const SizedBox(height: 8),
                const Text(
                  "Selecting a stop enables live proximity audio and notification alerts.",
                  style: TextStyle(
                    fontSize: 10,
                    color: Color(0xFF92400E),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
              elevation: 2,
            ),
            onPressed: () {
              if (tempStop == null || tempStop!.isEmpty) {
                _showSnackBar("⚠️ Please select a boarding stop first.");
              } else {
                setState(() {
                  _savedStop = tempStop!;
                });
              }
            },
            child: Text(
              "✨ Track Bus ${_busFirebaseId.replaceAll(RegExp(r'^[Bb]us\s*|^[Bb]'), '')} Now",
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveTrackingScreen() {
    final int nearestIdx = (_busLat != null && _busLng != null) ? _getNearestStopIndex(_busLat!, _busLng!) : 0;
    final int? eta = _calculateEtaMinutes(nearestIdx);

    final List<Marker> markers = [];
    for (var stopName in _routeStops) {
      final latLng = _getStopCoord(stopName);
      if (latLng != null) {
        final isMyStop = stopName == _savedStop || stopName.replaceAll(RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)'), '').trim() == _formattedSavedStop;
        markers.add(
          Marker(
            point: latLng,
            width: 22,
          height: 22,
          child: GestureDetector(
            onTap: () => _showSnackBar("Stop: ${stopName.replaceAll(RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)'), '').trim()}"),
            child: Container(
              decoration: BoxDecoration(
                color: isMyStop ? const Color(0xFF2563EB) : Colors.white,
                shape: BoxShape.circle,
                border: Border.all(
                  color: isMyStop ? Colors.white : const Color(0xFF2563EB),
                  width: 2.5,
                ),
                boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
              ),
              child: isMyStop
                  ? const Center(child: Icon(Icons.person, color: Colors.white, size: 12))
                  : null,
            ),
          ),
        ),
      );
      }
    }

    if (_busIsOnline && _renderLat != null && _renderLng != null) {
      markers.add(
        Marker(
          point: LatLng(_renderLat!, _renderLng!),
          width: 48,
          height: 56,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1B5E20),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))],
                ),
                child: Text(
                  "Bus ${_busFirebaseId.replaceAll(RegExp(r'^[Bb]us\s*|^[Bb]'), '')}",
                  style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: Colors.white),
                ),
              ),
              const Text("🚌", style: TextStyle(fontSize: 26)),
            ],
          ),
        ),
      );
    }

    // Nearest stop label
    if (_busIsOnline && _routeStops.isNotEmpty) {
      final nearStop = _routeStops[nearestIdx];
      final nearCoord = _getStopCoord(nearStop);
      if (nearCoord != null) {
        markers.add(
          Marker(
            point: nearCoord,
            width: 80,
            height: 30,
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1B5E20),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))],
                ),
                child: Text(
                  nearStop.replaceAll(RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)'), '').trim(),
                  style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: Colors.white),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        );
      }
    }

    final String nearestStopName = _busIsOnline && _routeStops.isNotEmpty ? (_routeStops[nearestIdx].replaceAll(RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)'), '').trim()) : "Searching…";

    return Stack(
      children: [
        // ── Full-screen map ──────────────────────────────────────────
        FlutterMap(
          options: const MapOptions(
            initialCenter: LatLng(13.047, 80.11),
            initialZoom: 13.0,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png',
              subdomains: const ['a', 'b', 'c', 'd'],
            ),
            if (_busRoutePoints.isNotEmpty)
              PolylineLayer(
                polylines: <Polyline<Object>>[
                  Polyline<Object>(
                    points: _busRoutePoints,
                    color: const Color(0xFF1B5E20),
                    strokeWidth: 4.0,
                    borderColor: Colors.white,
                    borderStrokeWidth: 1.5,
                  ),
                ],
              ),
            if (_busIsOnline && _renderLat != null && _renderLng != null && _busAccuracy != null)
              CircleLayer(
                circles: [
                  CircleMarker(
                    point: LatLng(_renderLat!, _renderLng!),
                    color: const Color(0xFF22C55E).withValues(alpha: 0.15),
                    borderColor: const Color(0xFF22C55E),
                    borderStrokeWidth: 1.2,
                    useRadiusInMeter: true,
                    radius: _busAccuracy!,
                  ),
                ],
              ),
            MarkerLayer(markers: markers),
          ],
        ),

        // ── Top bar: Back + Live badge ───────────────────────────────
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                GestureDetector(
                  onTap: () {
                    setState(() { _savedStop = ""; });
                    SharedPreferences.getInstance().then((p) => p.setString("savedStop", ""));
                  },
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
                    ),
                    child: const Icon(Icons.arrow_back, size: 20, color: Color(0xFF0F172A)),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: _busIsOnline ? const Color(0xFF16A34A) : const Color(0xFF64748B),
                    borderRadius: BorderRadius.circular(30),
                    boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.9),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _busIsOnline ? "LIVE GPS" : "OFFLINE",
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── Current nearest stop address pill (Rapido style) ─────────
        Positioned(
          left: 16,
          right: 16,
          bottom: 330,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(40),
              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 4))],
            ),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: _busIsOnline ? const Color(0xFF16A34A) : const Color(0xFF94A3B8),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _busIsOnline
                        ? "Bus 138 near: $nearestStopName"
                        : "Bus 138 is currently offline",
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0F172A),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.chevron_right, size: 18, color: Color(0xFF94A3B8)),
              ],
            ),
          ),
        ),

        // ── Breakdown banner (above bottom sheet) ────────────────────
        if (_breakdownActive)
          Positioned(
            left: 16,
            right: 16,
            bottom: 380,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFFCA5A5), width: 1.5),
                boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 8)],
              ),
              child: Row(
                children: [
                  const Text("🚨", style: TextStyle(fontSize: 18)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Bus 138 breakdown! Replacement: Bus $_replacementBus dispatched.",
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF991B1B)),
                    ),
                  ),
                ],
              ),
            ),
          ),

        // ── Bottom sheet ─────────────────────────────────────────────
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            height: 320,
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 20, offset: Offset(0, -4))],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // drag handle
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 10),
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFCBD5E1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // ETA pill / "Where do you want to go?" search-style header
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFF),
                      borderRadius: BorderRadius.circular(40),
                      border: Border.all(color: const Color(0xFFE2E8F0), width: 1.5),
                    ),
                    child: Row(
                      children: [
                        const Text("📍", style: TextStyle(fontSize: 16)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _savedStop.isNotEmpty
                                ? "Your stop: ${_formattedSavedStop.replaceAll(RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)'), '').trim()}"
                                : "Select your boarding stop",
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF334155),
                            ),
                          ),
                        ),
                        if (eta != null && _busIsOnline)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFFDCFCE7),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              "$eta min",
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF16A34A)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // "Bus 138 Route" label
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    "Bus 138 Route Stops",
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: Color(0xFF0F172A)),
                  ),
                ),
                const SizedBox(height: 10),

                // Horizontal scrolling stat chips
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _buildInfoChip("🚌", "Bus 138", "Active", const Color(0xFF2563EB)),
                        const SizedBox(width: 8),
                        _buildInfoChip(
                          "🕒",
                          _busIsOnline ? (eta != null ? "$eta min ETA" : "Passed") : "Offline",
                          _savedStop.isNotEmpty ? _formattedSavedStop.replaceAll(RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)'), '').trim() : "No stop set",
                          _busIsOnline ? const Color(0xFF16A34A) : const Color(0xFF94A3B8),
                        ),
                        const SizedBox(width: 8),
                        _buildInfoChip(
                          "🎯",
                          _busIsOnline && _busAccuracy != null ? "${_busAccuracy!.round()} m" : "—",
                          "GPS Accuracy",
                          const Color(0xFF7C3AED),
                        ),
                        const SizedBox(width: 8),
                        _buildInfoChip(
                          "±",
                          _busIsOnline ? _busUpdatedAt : "—",
                          "Last Updated",
                          const Color(0xFFF97316),
                        ),
                        const SizedBox(width: 16),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Route stop list (horizontal scrolling timeline)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 16, right: 16, bottom: 12),
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _routeStops.length,
                      itemBuilder: (context, index) {
                        final stopName = _routeStops[index];
                        final isMyStop = stopName == _savedStop;
                        final isCurrent = index == nearestIdx && _busIsOnline;
                        final isPast = index < nearestIdx && _busIsOnline;

                        Color dotColor = const Color(0xFFCBD5E1);
                        Color bgColor = const Color(0xFFF8FAFF);
                        Color textColor = const Color(0xFF64748B);
                        if (isPast) {
                          dotColor = const Color(0xFF94A3B8);
                        } else if (isCurrent) {
                          dotColor = const Color(0xFF16A34A);
                          bgColor = const Color(0xFFDCFCE7);
                          textColor = const Color(0xFF15803D);
                        } else if (isMyStop) {
                          dotColor = const Color(0xFF2563EB);
                          bgColor = const Color(0xFFDBEAFE);
                          textColor = const Color(0xFF1D4ED8);
                        }

                        return Row(
                          children: [
                            Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 110,
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: bgColor,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: isCurrent
                                          ? const Color(0xFF86EFAC)
                                          : isMyStop
                                              ? const Color(0xFF93C5FD)
                                              : const Color(0xFFE2E8F0),
                                      width: 1.5,
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Row(
                                        children: [
                                          Container(
                                            width: 8,
                                            height: 8,
                                            decoration: BoxDecoration(
                                              color: dotColor,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          if (isCurrent)
                                            const Text("🚌", style: TextStyle(fontSize: 10))
                                          else if (isMyStop)
                                            const Text("🏠", style: TextStyle(fontSize: 10))
                                          else if (isPast)
                                            const Text("✓", style: TextStyle(fontSize: 10, color: Color(0xFF94A3B8))),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        stopName.replaceAll(RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)'), '').trim(),
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: isCurrent || isMyStop ? FontWeight.w800 : FontWeight.bold,
                                          color: textColor,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (isMyStop) ...[
                                        const SizedBox(height: 4),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF2563EB),
                                            borderRadius: BorderRadius.circular(10),
                                          ),
                                          child: const Text("My Stop", style: TextStyle(fontSize: 7, fontWeight: FontWeight.w900, color: Colors.white)),
                                        ),
                                      ] else if (isCurrent) ...[
                                        const SizedBox(height: 4),
                                        const Text("Bus here", style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Color(0xFF16A34A))),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            if (index < _routeStops.length - 1)
                              Container(
                                width: 20,
                                height: 2,
                                color: isPast ? const Color(0xFF22C55E) : const Color(0xFFE2E8F0),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // offline overlay on top of map
        if (!_busIsOnline)
          Positioned(
            left: 60,
            right: 60,
            top: MediaQuery.of(context).size.height * 0.25,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 16)],
              ),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("📡", style: TextStyle(fontSize: 40)),
                  SizedBox(height: 8),
                  Text("Driver not tracking", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF374151))),
                  SizedBox(height: 4),
                  Text("Bus 138 GPS is offline. Map updates automatically when driver starts.", textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildInfoChip(String icon, String value, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.2), width: 1.2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(icon, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: color)),
              Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: color.withValues(alpha: 0.7))),
            ],
          ),
        ],
      ),
    );
  }



  // ===========================================================================
  // CAMPUS NAVIGATION TAB
  // ===========================================================================
  String _campusFrom = "Main Entrance Gate";
  String _campusTo = "Admin / Admission Block";
  Polyline? _campusRoute;
  String _campusWalkInfo = "";

  Widget _buildCampusNavTab() {
    final MapController campusMapController = MapController();

    void updateCampusRoute() {
      final fromPt = campusPoints.firstWhere((p) => p.name == _campusFrom);
      final toPt = campusPoints.firstWhere((p) => p.name == _campusTo);

      if (_campusFrom == _campusTo) {
        setState(() {
          _campusRoute = null;
          _campusWalkInfo = "⚠️ Select different From and To points.";
        });
        return;
      }

      final dist = _haversineKm(fromPt.coords.latitude, fromPt.coords.longitude, toPt.coords.latitude, toPt.coords.longitude);
      final walkTime = (dist * 12).ceil();

      setState(() {
        _campusRoute = Polyline(
          points: [fromPt.coords, toPt.coords],
          color: const Color(0xFF16A34A),
          strokeWidth: 4.5,
          borderColor: Colors.white,
          borderStrokeWidth: 1,
        );
        _campusWalkInfo = "🚶 Distance: ${(dist * 1000).toStringAsFixed(0)}m | ⏱️ Walk time: $walkTime min";
      });

      final bounds = LatLngBounds.fromPoints([fromPt.coords, toPt.coords]);
      campusMapController.fitCamera(CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(50)));
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          color: Colors.white,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("FROM", style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Color(0xFF64748B))),
                        const SizedBox(height: 4),
                        DropdownButtonFormField<String>(
                          initialValue: _campusFrom,
                          decoration: InputDecoration(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(30)),
                          ),
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0F172A), fontSize: 12),
                          items: campusPoints.map((pt) {
                            return DropdownMenuItem(value: pt.name, child: Text(pt.name));
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setState(() {
                                _campusFrom = val;
                              });
                              updateCampusRoute();
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("TO", style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Color(0xFF64748B))),
                        const SizedBox(height: 4),
                        DropdownButtonFormField<String>(
                          initialValue: _campusTo,
                          decoration: InputDecoration(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(30)),
                          ),
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0F172A), fontSize: 12),
                          items: campusPoints.map((pt) {
                            return DropdownMenuItem(value: pt.name, child: Text(pt.name));
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setState(() {
                                _campusTo = val;
                              });
                              updateCampusRoute();
                            }
                          },
                        ),
                      ],
                    ),
                  )
                ],
              ),
              if (_campusWalkInfo.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0FDF4),
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: Center(
                    child: Text(
                      _campusWalkInfo,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: Color(0xFF166534)),
                    ),
                  ),
                )
              ]
            ],
          ),
        ),

        Container(
          height: 52,
          padding: const EdgeInsets.symmetric(vertical: 8),
          color: Colors.white,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: campusPoints.slice(1).length,
            itemBuilder: (context, idx) {
              final pt = campusPoints[idx + 1];
              return Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: InputChip(
                  avatar: Text(pt.icon),
                  label: Text(pt.name.split(' ')[0]),
                  labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 11),
                  onPressed: () {
                    setState(() {
                      _campusTo = pt.name;
                    });
                    updateCampusRoute();
                  },
                ),
              );
            },
          ),
        ),

        Expanded(
          child: FlutterMap(
            mapController: campusMapController,
            options: const MapOptions(
              initialCenter: LatLng(13.050, 80.075),
              initialZoom: 16.0,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png',
                subdomains: const ['a', 'b', 'c', 'd'],
              ),
              if (_campusRoute != null)
                PolylineLayer(
                  polylines: [_campusRoute!],
                ),
              MarkerLayer(
                markers: campusPoints.map((pt) {
                  return Marker(
                    point: pt.coords,
                    width: 32,
                    height: 32,
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 4)],
                      ),
                      child: Center(
                        child: Text(pt.icon, style: const TextStyle(fontSize: 16)),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // PROFILE TAB
  // ===========================================================================
  Widget _buildProfileTab() {
    final TextEditingController nameCtrl = TextEditingController(text: _studentName);
    final TextEditingController deptCtrl = TextEditingController(text: _studentDept);
    String tempYear = _studentYear;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Column(
              children: [
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE2E8F0),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFF2563EB), width: 3),
                  ),
                  child: const Center(child: Text("🎓", style: TextStyle(fontSize: 54))),
                ),
                const SizedBox(height: 12),
                Text(
                  _studentName,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const Text(
                  "Panimalar Smart Transit Account",
                  style: TextStyle(color: Color(0xFF64748B), fontSize: 12, fontWeight: FontWeight.bold),
                )
              ],
            ),
          ),
          const SizedBox(height: 24),

          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xFFE2E8F0), width: 1.5),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text("STUDENT DETAILS", style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF64748B), letterSpacing: 0.5)),
                const SizedBox(height: 16),
                
                const Text("FULL NAME", style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF64748B))),
                const SizedBox(height: 6),
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(30)),
                  ),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),

                const Text("YEAR OF STUDY", style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF64748B))),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  initialValue: tempYear,
                  decoration: InputDecoration(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(30)),
                  ),
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0F172A), fontSize: 13),
                  items: const [
                    DropdownMenuItem(value: "1st Year", child: Text("1st Year")),
                    DropdownMenuItem(value: "2nd Year", child: Text("2nd Year")),
                    DropdownMenuItem(value: "3rd Year", child: Text("3rd Year")),
                    DropdownMenuItem(value: "4th Year", child: Text("4th Year")),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      tempYear = val;
                    }
                  },
                ),
                const SizedBox(height: 16),

                const Text("DEPARTMENT", style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF64748B))),
                const SizedBox(height: 6),
                TextField(
                  controller: deptCtrl,
                  decoration: InputDecoration(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(30)),
                  ),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 24),

                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                  ),
                  onPressed: () {
                    _saveProfile(nameCtrl.text.trim(), tempYear, deptCtrl.text.trim());
                  },
                  child: const Text("💾 Save Profile", style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    side: const BorderSide(color: Color(0xFF2563EB)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                  ),
                  onPressed: widget.onSwitchRole,
                  child: const Text("🔄 Logout", style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                )
              ],
            ),
          )
        ],
      ),
    );
  }
}

extension ListSlice<T> on List<T> {
  List<T> slice(int start, [int? end]) {
    int s = start < 0 ? length + start : start;
    int e = end == null 
        ? length 
        : (end < 0 ? length + end : end);
    
    s = s.clamp(0, length);
    e = e.clamp(s, length);
    return sublist(s, e);
  }
}

// ===========================================================================
// HELPER MARQUEE AND LEGEND WIDGETS
// ===========================================================================
class MarqueeNoticeBar extends StatefulWidget {
  final String text;
  final VoidCallback? onTap;
  const MarqueeNoticeBar({super.key, required this.text, this.onTap});

  @override
  State<MarqueeNoticeBar> createState() => _MarqueeNoticeBarState();
}

class _MarqueeNoticeBarState extends State<MarqueeNoticeBar> {
  late ScrollController _scrollController;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startScrolling();
    });
  }

  void _startScrolling() {
    _timer = Timer.periodic(const Duration(milliseconds: 30), (timer) {
      if (!_scrollController.hasClients) return;
      
      final maxExtent = _scrollController.position.maxScrollExtent;
      final currentOffset = _scrollController.offset;
      
      if (maxExtent > 0) {
        if (currentOffset >= maxExtent) {
          _scrollController.jumpTo(0.0);
        } else {
          _scrollController.jumpTo(currentOffset + 0.8);
        }
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      child: Row(
        children: [
          Container(
            color: const Color(0xFFFF5252),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.center,
            child: const Text(
              "UPDATE",
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: widget.onTap,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF1E40AF), Color(0xFF2563EB)],
                  ),
                ),
                child: SingleChildScrollView(
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  physics: const NeverScrollableScrollPhysics(),
                  child: Row(
                    children: [
                      for (int i = 0; i < 5; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 60.0, left: 10.0),
                          child: Align(
                            alignment: Alignment.center,
                            child: Text(
                              widget.text,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  const LegendItem({super.key, required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            color: Color(0xFF64748B),
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

// ===========================================================================
// ROLE SELECTION SCREEN
// ===========================================================================
class RoleSelectionScreen extends StatelessWidget {
  final Function(String) onSelectRole;
  const RoleSelectionScreen({super.key, required this.onSelectRole});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFF8FBFF), Color(0xFFE6ECFF)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 40.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(),
                Center(
                  child: Container(
                    width: 90,
                    height: 90,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(30),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF2563EB).withValues(alpha: 0.15),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                      border: Border.all(
                        color: const Color(0xFF2563EB).withValues(alpha: 0.1),
                        width: 2,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: const Text("🚌", style: TextStyle(fontSize: 48)),
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  "PANIMALAR",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                    color: Color(0xFF1E3A8A),
                  ),
                ),
                const Text(
                  "Smart Transit Platform",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF64748B),
                  ),
                ),
                const Spacer(),
                const Text(
                  "SELECT YOUR ROLE",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                    color: Color(0xFF64748B),
                  ),
                ),
                const SizedBox(height: 16),
                GestureDetector(
                  onTap: () => onSelectRole("student"),
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: const Color(0xFFDBE2F8), width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF0F172A).withValues(alpha: 0.05),
                          blurRadius: 15,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: const Color(0xFFEEF2FF),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          alignment: Alignment.center,
                          child: const Text("🎓", style: TextStyle(fontSize: 28)),
                        ),
                        const SizedBox(width: 16),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "I am a Student",
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                "Track live buses, find routes, and view schedules.",
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF64748B),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.arrow_forward_ios, size: 16, color: Color(0xFF64748B)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                GestureDetector(
                  onTap: () => onSelectRole("driver"),
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: const Color(0xFFDBE2F8), width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF0F172A).withValues(alpha: 0.05),
                          blurRadius: 15,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFFBEB),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          alignment: Alignment.center,
                          child: const Text("👔", style: TextStyle(fontSize: 28)),
                        ),
                        const SizedBox(width: 16),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "I am a Driver",
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                "Share live GPS location, log boarding, and report alerts.",
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF64748B),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.arrow_forward_ios, size: 16, color: Color(0xFF64748B)),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                const Text(
                  "Panimalar Engineering College",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF64748B),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// DRIVER SHELL & LOCALIZATION MAP
// ===========================================================================
final Map<String, Map<String, String>> driverLang = {
  'en': {
    'appTitle': "Driver App",
    'appSubtitle': "Panimalar Engineering College",
    'langLabel': "Choose Language",
    'sectionLogin': "Driver Login",
    'busNumber': "Bus Number",
    'busPassword': "Password",
    'signIn': "Sign In",
    'errorEnter': "Please enter bus number and password.",
    'errorInvalid': "Invalid bus number or password.",
    'dashboardLabel': "Driver Dashboard",
    'busLabel': "Bus Number",
    'statusLabel': "Status",
    'routeLabel': "Poonamallee Campus",
    'gpsLabel': "Live GPS Status",
    'latLabel': "Latitude",
    'lngLabel': "Longitude",
    'accLabel': "Accuracy",
    'updatedLabel': "Updated",
    'highlightTitle': "Your bus is connected to campus fleet platform.",
    'highlightText': "Start tracking to broadcast location.",
    'startTracking': "Start Tracking",
    'stopTracking': "Stop Tracking",
    'reportBreakdown': "Report Breakdown",
    'fleetLabel': "Live fleet dashboard",
    'etaTitle': "Route ETA",
    'nextStopLabel': "Next stop:",
    'healthTitle': "Vehicle health",
    'boardingTitle': "Student boarding",
    'logBoarding': "Log boarding",
    'breakdownSection': "🚨 Breakdown Alert (Student Notification)",
    'replacementBus': "Replacement Bus Number",
    'detectedLocation': "Detected Location",
    'sendAlert': "Send Alert to Students",
    'langLabelDash': "Language",
    'logout': "Logout",
    'trackingStopped': "Tracking stopped.",
    'trackingStarted': "Live GPS tracking started.",
    'boardingLogged': "Student boarding logged.",
    'allBoarded': "All students already boarded.",
    'replacementErrorEmpty': "Enter replacement bus number",
    'locationUnavailable': "Location not available yet",
    'alertSaved': "✅ Alert saved to Firebase",
    'bottomInfo': "Panimalar Engineering College campus transport",
    'notifyRoute': "Notify Buses on Same Route",
    'autoAlertNearby': "Auto-alert nearby buses to collect stranded students",
    'notifyExpl': "When your bus breaks down, other buses on the same route are automatically notified via Firebase to pick up your students.",
    'sendBreakdownBuses': "Send Breakdown to Route Buses",
    'speechTitle': "Speech Monitor",
    'speechWaiting': "Waiting for tracking…",
    'speechActive': "Speech monitoring active.",
    'speakingTime': "Speaking time",
    'sessions': "Sessions",
    'longest': "Longest",
    'pctDrive': "% drive time",
    'speechUsage': "Speech usage",
    'sessionLog': "Session log",
    'speechTooMuch': "Speaking too much while driving — admin notified."
  },
  'ta': {
    'appTitle': "டிரைவர் ஆப்",
    'appSubtitle': "பனிமலர் பொறியியல் கல்லூரி",
    'langLabel': "மொழியைத் தேர்வு செய்யவும்",
    'sectionLogin': "டிரைவர் உள்நுழைவு",
    'busNumber': "பஸ் எண்",
    'busPassword': "கடவுச்சொல்",
    'signIn': "உள்நுழை",
    'errorEnter': "பஸ் எண் மற்றும் கடவுச்சொல்லை உள்ளிடவும்.",
    'errorInvalid': "தவறான பஸ் எண் அல்லது கடவுச்சொல்.",
    'dashboardLabel': "டிரைவர் டேஷ்போர்டு",
    'busLabel': "பஸ் எண்",
    'statusLabel': "நிலை",
    'routeLabel': "பூந்தமல்லி வளாகம்",
    'gpsLabel': "நேரலை GPS நிலை",
    'latLabel': "அட்சரேகை",
    'lngLabel': "தீர்க்கரேகை",
    'accLabel': "துல்லியம்",
    'updatedLabel': "புதுப்பிக்கப்பட்டது",
    'highlightTitle': "உங்கள் பஸ் வளாக போக்குவரத்து நெட்வொர்க்குடன் இணைக்கப்பட்டுள்ளது.",
    'highlightText': "இடத்தை பகிர டிராக்கிங் தொடங்கவும்.",
    'startTracking': "டிராக்கிங் தொடங்கு",
    'stopTracking': "டிராக்கிங் நிறுத்து",
    'reportBreakdown': "பழுது எச்சரிக்கை",
    'fleetLabel': "நேரலை கடற்படை டேஷ்போர்டு",
    'etaTitle': "வழி வருகை நேரம் (ETA)",
    'nextStopLabel': "அடுத்த நிறுத்தம்:",
    'healthTitle': "வாகன ஆரோக்கியம்",
    'boardingTitle': "மாணவர் ஏறுதல்",
    'logBoarding': "ஏறுதல் பதிவு",
    'breakdownSection': "🚨 பஸ் பழுது எச்சரிக்கை",
    'replacementBus': "மாற்று பஸ் எண்",
    'detectedLocation': "கண்டறியப்பட்ட இடம்",
    'sendAlert': "மாணவர்களுக்கு எச்சரிக்கை அனுப்பு",
    'langLabelDash': "மொழி",
    'logout': "வெளியேறு",
    'trackingStopped': "டிராக்கிங் நிறுத்தப்பட்டது.",
    'trackingStarted': "நேரலை GPS டிராக்கிங் தொடங்கப்பட்டது.",
    'boardingLogged': "மாணவர் ஏறுதல் பதிவு செய்யப்பட்டது.",
    'allBoarded': "அனைத்து மாணவர்களும் ஏற்கனவே ஏறிவிட்டனர்.",
    'replacementErrorEmpty': "மாற்று பஸ் எண்ணை உள்ளிடவும்",
    'locationUnavailable': "இடம் இன்னும் கிடைக்கவில்லை",
    'alertSaved': "✅ எச்சரிக்கை சேமிக்கப்பட்டது",
    'bottomInfo': "பனிமலர் பொறியியல் கல்லூரி வளாக போக்குவரத்து",
    'notifyRoute': "ஒரே வழியில் செல்லும் பேருந்துகளுக்கு அறிவிக்கவும்",
    'autoAlertNearby': "அருகிலுள்ள பேருந்துகளை தானாக எச்சரிக்கவும்",
    'notifyExpl': "உங்கள் பேருந்து பழுதடைந்தால், அதே வழியில் உள்ள மற்ற பேருந்துகளுக்கு தானாகவே அறிவிக்கப்பட்டு மாணவர்களை அழைத்துச் செல்லும்.",
    'sendBreakdownBuses': "பேருந்துகளுக்கு பழுது அறிவிப்பை அனுப்பு",
    'speechTitle': "பேச்சு மானிட்டர்",
    'speechWaiting': "டிராக்கிங்கிற்காக காத்திருக்கிறது...",
    'speechActive': "பேச்சு கண்காணிப்பு செயலில் உள்ளது.",
    'speakingTime': "பேசும் நேரம்",
    'sessions': "அமர்வுகள்",
    'longest': "நீண்ட நேரம்",
    'pctDrive': "% ஓட்டுநர் நேரம்",
    'speechUsage': "பேச்சு பயன்பாடு",
    'sessionLog': "அமர்வு பதிவு",
    'speechTooMuch': "வாகனம் ஓட்டும்போது அதிகமாகப் பேசுகிறார் — நிர்வாகிக்கு அறிவிக்கப்பட்டது."
  },
  'te': {
    'appTitle': "డ్రైవర్ యాప్",
    'appSubtitle': "పనిమలర్ ఇంజనీరింగ్ కళాశాల",
    'langLabel': "భాషను ఎంచుకోండి",
    'sectionLogin': "డ్రైవర్ లాగిన్",
    'busNumber': "బస్సు సంఖ్య",
    'busPassword': "పాస్ వర్డ్",
    'signIn': "లాగిన్",
    'errorEnter': "బస్సు సంఖ్య మరియు పాస్ వర్డ్ నమోదు చేయండి.",
    'errorInvalid': "చెల్లని బస్సు సంఖ్య లేదా పాస్ వర్డ్.",
    'dashboardLabel': "డ్రైవర్ డాష్ బోర్డ్",
    'busLabel': "బస్సు సంఖ్య",
    'statusLabel': "స్థితి",
    'routeLabel': "పూనమల్లి క్యాంపస్",
    'gpsLabel': "లైవ్ GPS స్థితి",
    'latLabel': "అక్షాంశం",
    'lngLabel': "రేఖాంశం",
    'accLabel': "ఖచ్చితత్వం",
    'updatedLabel': "నవీకరించబడింది",
    'highlightTitle': "మీ బస్సు క్యాంపస్ రవాణా నెట్ వర్క్ తో అనుసంధానించబడింది.",
    'highlightText': "స్థానాన్ని పంచుకోవడానికి ట్రాకింగ్ ప్రారంభించండి.",
    'startTracking': "ట్రాకింగ్ ప్రారంభించు",
    'stopTracking': "ట్రాకింగ్ ఆపివేయి",
    'reportBreakdown': "బ్రేక్ డౌన్ నివేదించు",
    'fleetLabel': "లైవ్ ఫ్లీట్ డాష్ బోర్డ్",
    'etaTitle': "మార్గం ETA",
    'nextStopLabel': "తదుపరి స్టాప్:",
    'healthTitle': "వాహన ఆరోగ్యం",
    'boardingTitle': "విద్యార్థుల బోర్డింగ్",
    'logBoarding': "బోర్డింగ్ నమోదు",
    'breakdownSection': "🚨 బస్సు బ్రేక్ డౌన్ అలర్ట్",
    'replacementBus': "ప్రత్యామ్నాయ బస్సు సంఖ్య",
    'detectedLocation': "గుర్తించిన స్థానం",
    'sendAlert': "విద్యార్థులకు అలర్ట్ పంపండి",
    'langLabelDash': "భాష",
    'logout': "లాగ్ అవుట్",
    'trackingStopped': "ట్రాకింగ్ ఆపివేయబడింది.",
    'trackingStarted': "లైవ్ GPS ట్రాకింగ్ ప్రారంభమైంది.",
    'boardingLogged': "విద్యార్థి బోర్డింగ్ నమోదైంది.",
    'allBoarded': "విద్యార్థులందరూ ఇప్పటికే బస్సు ఎక్కారు.",
    'replacementErrorEmpty': "ప్రత్యామ్నాయ బస్సు సంఖ్యను నమోదు చేయండి",
    'locationUnavailable': "స్థానం ఇంకా అందుబాటులో లేదు",
    'alertSaved': "✅ అలర్ట్ సేవ్ చేయబడింది",
    'bottomInfo': "పనిమలర్ ఇంజనీరింగ్ కళాశాల క్యాంపస్ రవాణా",
    'notifyRoute': "అదే మార్గంలో వెళ్లే బస్సులకు తెలియజేయండి",
    'autoAlertNearby': "సమీపంలోని బస్సులను ఆటోమేటిక్ గా అలర్ట్ చేయండి",
    'notifyExpl': "మీ బస్సు బ్రేక్ డౌన్ అయినప్పుడు, అదే మార్గంలో ఉన్న ఇతర బస్సులకు విద్యార్థులను తీసుకెళ్లడానికి ఆటోమేటిక్ గా తెలియజేయబడుతుంది.",
    'sendBreakdownBuses': "బస్సులకు బ్రేక్ డౌన్ అలర్ట్ పంపండి",
    'speechTitle': "స్పీచ్ మానిటర్",
    'speechWaiting': "ట్రాకింగ్ కోసం నిరీక్షణ...",
    'speechActive': "స్పీచ్ మానిటరింగ్ సక్రియంగా ఉంది.",
    'speakingTime': "మాట్లాడే సమయం",
    'sessions': "సెషన్లు",
    'longest': "అత్యధిక సమయం",
    'pctDrive': "% డ్రైవింగ్ సమయం",
    'speechUsage': "స్పీచ్ వినియోగం",
    'sessionLog': "సెషన్ లాగ్",
    'speechTooMuch': "డ్రైవింగ్ చేస్తున్నప్పుడు ఎక్కువగా మాట్లాడుతున్నారు — అడ్మిన్ కు తెలియజేయబడింది."
  }
};

class DriverShell extends StatefulWidget {
  final VoidCallback onSwitchRole;
  const DriverShell({super.key, required this.onSwitchRole});

  @override
  State<DriverShell> createState() => _DriverShellState();
}

class _DriverShellState extends State<DriverShell> {
  bool _isLoggedIn = false;
  String _driverBus = "";
  String _currentLang = "en";

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  void _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _currentLang = prefs.getString("driver_lang") ?? "en";
      _driverBus = prefs.getString("driver_bus") ?? "";
      _isLoggedIn = _driverBus.isNotEmpty;
    });
  }

  void _login(String busId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("driver_bus", busId);
    setState(() {
      _driverBus = busId;
      _isLoggedIn = true;
    });
  }

  void _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("driver_bus", "");
    setState(() {
      _driverBus = "";
      _isLoggedIn = false;
    });
  }

  void _updateLanguage(String lang) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("driver_lang", lang);
    setState(() {
      _currentLang = lang;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isLoggedIn) {
      return DriverLoginScreen(
        currentLang: _currentLang,
        onLogin: _login,
        onLanguageChanged: _updateLanguage,
        onSwitchRole: widget.onSwitchRole,
      );
    } else {
      return DriverDashboard(
        driverBus: _driverBus,
        currentLang: _currentLang,
        onLogout: _logout,
        onLanguageChanged: _updateLanguage,
        onSwitchRole: widget.onSwitchRole,
      );
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// DRIVER LOGIN SCREEN
// ══════════════════════════════════════════════════════════════════════════════
class DriverLoginScreen extends StatefulWidget {
  final String currentLang;
  final Function(String) onLogin;
  final Function(String) onLanguageChanged;
  final VoidCallback onSwitchRole;

  const DriverLoginScreen({
    super.key,
    required this.currentLang,
    required this.onLogin,
    required this.onLanguageChanged,
    required this.onSwitchRole,
  });

  @override
  State<DriverLoginScreen> createState() => _DriverLoginScreenState();
}

class _DriverLoginScreenState extends State<DriverLoginScreen> {
  final TextEditingController _busController = TextEditingController();
  final TextEditingController _passController = TextEditingController();
  String _errorMsg = "";

  String t(String key) {
    return driverLang[widget.currentLang]?[key] ?? key;
  }

  void _attemptLogin() {
    final bus = _busController.text.trim().toUpperCase();
    final pass = _passController.text.trim();

    if (bus.isEmpty || pass.isEmpty) {
      setState(() {
        _errorMsg = t('errorEnter');
      });
      return;
    }

    if ((bus == 'BUS101' || bus == 'BUS102') && pass == '1234') {
      setState(() {
        _errorMsg = "";
      });
      widget.onLogin(bus);
    } else {
      setState(() {
        _errorMsg = t('errorInvalid');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFF8FBFF), Color(0xFFE6ECFF)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Top Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFDBE2F8)),
                        ),
                        alignment: Alignment.center,
                        child: const Text("ðŸš", style: TextStyle(fontSize: 22)),
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t('appTitle'),
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF1E3A8A),
                            ),
                          ),
                          Text(
                            t('appSubtitle'),
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF64748B),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      )
                    ],
                  ),
                  const SizedBox(height: 36),

                  // Login Form Card
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: const Color(0xFFDBE2F8), width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF0F172A).withValues(alpha: 0.05),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          t('sectionLogin'),
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF64748B),
                            letterSpacing: 1.0,
                          ),
                        ),
                        const SizedBox(height: 20),

                        // Bus Number Input
                        Text(
                          t('busNumber'),
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF334155)),
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _busController,
                          decoration: InputDecoration(
                            hintText: "e.g. BUS101",
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(22)),
                          ),
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 16),

                        // Password Input
                        Text(
                          t('busPassword'),
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF334155)),
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _passController,
                          obscureText: true,
                          decoration: InputDecoration(
                            hintText: "••••",
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(22)),
                          ),
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 20),

                        if (_errorMsg.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12.0),
                            child: Text(
                              _errorMsg,
                              style: const TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ),

                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF2563EB),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                            elevation: 0,
                          ),
                          onPressed: _attemptLogin,
                          child: Text(t('signIn'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Language Card
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: const Color(0xFFDBE2F8), width: 1.2),
                    ),
                    child: Column(
                      children: [
                        Text(t('langLabel'), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF334155))),
                        const SizedBox(height: 10),
                        SegmentedButton<String>(
                          style: SegmentedButton.styleFrom(
                            selectedBackgroundColor: const Color(0xFF2563EB),
                            selectedForegroundColor: Colors.white,
                          ),
                          segments: const [
                            ButtonSegment(value: 'en', label: Text('English')),
                            ButtonSegment(value: 'ta', label: Text('தமிழ்')),
                            ButtonSegment(value: 'te', label: Text('తెలుగు')),
                          ],
                          selected: {widget.currentLang},
                          onSelectionChanged: (set) {
                            if (set.isNotEmpty) {
                              widget.onLanguageChanged(set.first);
                            }
                          },
                        )
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Back to Student role switcher
                  TextButton(
                    onPressed: widget.onSwitchRole,
                    child: const Text(
                      "🎓 Switch to Student Mode",
                      style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF2563EB)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
// DRIVER DASHBOARD
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
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

class _DriverDashboardState extends State<DriverDashboard> {
  // Geolocator telemetry
  bool _isTracking = false;
  Position? _currentPosition;
  StreamSubscription<Position>? _positionSubscription;

  String _appStatus = "Offline";
  double _latitude = 0.0;
  double _longitude = 0.0;
  double _accuracy = 0.0;
  String _updatedAt = "--";
  String _gpsStatus = "Offline";
  String _replacementBus = "";
  bool _notifyRouteBusesEnabled = false;

  // Firebase status & sync states
  bool _firebaseConnected = false;
  StreamSubscription? _connectedSubscription;
  String _syncStatusText = "Firebase sync ready";
  String _syncTimestamp = "--";
  bool _isSyncing = false;

  // Geofence & Next stop state
  String _nextStop = "Campus Gate";
  String _eta = "--";

  // Student boarding log
  int _attendanceCount = 0;
  final int _attendanceCapacity = 14;

  // Breakdown handling
  bool _breakdownActive = false;
  final TextEditingController _replacementController = TextEditingController();
  String _routeNotifyStatus = "";

  // Bus Ready banner state
  bool _showBusReadyBanner = false;
  int _busReadyCountdown = 10;
  Timer? _busReadyTimer;
  Timer? _busReadyCountdownTimer;

  // Map center controller
  final MapController _mapController = MapController();

  // Speech monitor simulation fields
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

  final double _warnThresholdPct = 20.0;

  // Constants matching the HTML setup
  final List<Map<String, dynamic>> _routeStops = [
    {'name': 'Campus Gate', 'lat': 13.0486, 'lng': 80.0753},
    {'name': 'Library', 'lat': 13.0488, 'lng': 80.0780},
    {'name': 'Hostel', 'lat': 13.0468, 'lng': 80.0775},
    {'name': 'Exam Block', 'lat': 13.0454, 'lng': 80.0742}
  ];

  String t(String key) {
    return driverLang[widget.currentLang]?[key] ?? key;
  }

  @override
  void initState() {
    super.initState();
    _startFirebaseConnectedListener();
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _connectedSubscription?.cancel();
    _smSimulationTimer?.cancel();
    _waveTimer?.cancel();
    _busReadyTimer?.cancel();
    _busReadyCountdownTimer?.cancel();
    _replacementController.dispose();
    super.dispose();
  }

  void _showBusReadyNotification() {
    _busReadyTimer?.cancel();
    _busReadyCountdownTimer?.cancel();

    setState(() {
      _showBusReadyBanner = true;
      _busReadyCountdown = 10;
    });

    HapticFeedback.vibrate();

    // Countdown every second
    _busReadyCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }
      setState(() {
        _busReadyCountdown--;
      });
      if (_busReadyCountdown <= 0) {
        timer.cancel();
      }
    });

    // Auto-dismiss after 10 seconds
    _busReadyTimer = Timer(const Duration(seconds: 10), () {
      if (mounted) {
        setState(() {
          _showBusReadyBanner = false;
        });
      }
    });
  }

  void _startFirebaseConnectedListener() {
    if (Firebase.apps.isEmpty) return;
    _connectedSubscription = FirebaseDatabase.instance.ref('.info/connected').onValue.listen((event) {
      final connected = event.snapshot.value == true;
      setState(() {
        _firebaseConnected = connected;
        _syncStatusText = connected ? "✅ Firebase connected" : "âš ï¸ Firebase offline — retrying…";
        _syncTimestamp = _formattedTimeNow();
      });
    });
  }

  String _formattedTimeNow() {
    final now = DateTime.now();
    return "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
  }

  // Firebase sets coordinates with visual sync loading spinner
  Future<void> _fbUpdateLocation(Position pos) async {
    if (Firebase.apps.isEmpty) return;
    setState(() {
      _isSyncing = true;
      _syncStatusText = "Syncing…";
    });

    final data = {
      'lat': pos.latitude,
      'lng': pos.longitude,
      'acc': pos.accuracy,
      'status': _isTracking ? (_breakdownActive ? 'broken' : 'tracking') : 'offline',
      'updatedAt': DateTime.now().toIso8601String()
    };

    try {
      await FirebaseDatabase.instance.ref('liveLocations/${widget.driverBus}').set(data);
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _syncStatusText = "✅ Synced to Firebase";
          _syncTimestamp = _formattedTimeNow();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _syncStatusText = "âŒ Sync failed — check connection";
        });
      }
    }
  }

  Future<void> _fbSetOffline() async {
    if (Firebase.apps.isEmpty) return;
    setState(() {
      _isSyncing = true;
    });

    final data = {
      'lat': _currentPosition?.latitude ?? 13.0486,
      'lng': _currentPosition?.longitude ?? 80.0753,
      'acc': _currentPosition?.accuracy ?? 10.0,
      'status': 'offline',
      'updatedAt': DateTime.now().toIso8601String()
    };

    try {
      await FirebaseDatabase.instance.ref('liveLocations/${widget.driverBus}').set(data);
      setState(() {
        _isSyncing = false;
        _syncStatusText = "â˜ï¸ Offline status saved";
      });
    } catch (_) {
      setState(() {
        _isSyncing = false;
      });
    }
  }

  // Start tracking
  void _startTracking() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        _showDialog("Permission Required", "GPS Location permissions are required to start vehicle tracking.");
        return;
      }
    }

    setState(() {
      _isTracking = true;
      _appStatus = "Online";
      _syncStatusText = "Starting GPS stream...";
    });

    // Show bus ready banner to driver
    _showBusReadyNotification();

    // Write initial tracking status
    Position initialPos = await Geolocator.getCurrentPosition();
    setState(() {
      _currentPosition = initialPos;
      _latitude = initialPos.latitude;
      _longitude = initialPos.longitude;
      _accuracy = initialPos.accuracy;
      _updatedAt = _formattedTimeNow();
      _gpsStatus = "Active";
    });
    await _fbUpdateLocation(initialPos);

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((Position position) {
      setState(() {
        _currentPosition = position;
        _latitude = position.latitude;
        _longitude = position.longitude;
        _accuracy = position.accuracy;
        _updatedAt = _formattedTimeNow();
        _mapController.move(LatLng(position.latitude, position.longitude), _mapController.camera.zoom);
      });
      _fbUpdateLocation(position);
      _checkGeofences(position);
    });

    // Start speech monitor simulations
    _startSpeechMonitor();
  }

  void _stopTracking() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;

    setState(() {
      _isTracking = false;
      _appStatus = "Offline";
      _gpsStatus = "Offline";
    });

    await _fbSetOffline();
    _stopSpeechMonitor();
  }

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

    // Update next stop and ETA
    setState(() {
      if (minDistance < 100) {
        _nextStop = closestStopName;
        _eta = "Arrived";
      } else {
        _nextStop = closestStopName;
        int estMinutes = (minDistance / 250).ceil(); // ~15km/h estimation
        _eta = "$estMinutes min";
      }
    });
  }

  void _reportBreakdown() {
    if (!_isTracking) return;
    setState(() {
      _breakdownActive = true;
      _appStatus = "Broken Down";
    });

    final data = {
      'busId': widget.driverBus,
      'bus': widget.driverBus,
      'replacement': 'Pending',
      'lat': _currentPosition?.latitude ?? 13.0486,
      'lng': _currentPosition?.longitude ?? 80.0753,
      'time': DateTime.now().toIso8601String(),
      'timestamp': DateTime.now().millisecondsSinceEpoch
    };

    if (Firebase.apps.isNotEmpty) {
      FirebaseDatabase.instance.ref('breakdowns/${widget.driverBus}').set(data);
    }

    if (_currentPosition != null) {
      _fbUpdateLocation(_currentPosition!);
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
      'lat': _currentPosition?.latitude ?? 13.0486,
      'lng': _currentPosition?.longitude ?? 80.0753,
      'time': DateTime.now().toIso8601String(),
      'timestamp': DateTime.now().millisecondsSinceEpoch
    };

    try {
      await FirebaseDatabase.instance.ref('breakdowns/${widget.driverBus}').set(data);
      _showDialog("Success", t('alertSaved'));
      setState(() {
        _replacementBus = repBus;
        _notifyRouteBusesEnabled = true;
      });
    } catch (e) {
      _showDialog("Error", "Could not send breakdown alert: $e");
    }
  }

  Future<void> _sendBreakdownToRouteBuses() async {
    setState(() {
      _routeNotifyStatus = "📡 Broadcasting to Route 5 buses...";
    });

    try {
      // Broadcast alerts to BUS102, BUS105 under a route notifications node
      final alertData = {
        'sourceBus': widget.driverBus,
        'alertText': "Breakdown reported for ${widget.driverBus}. Stranded students need pickup near $_nextStop.",
        'replacement': _replacementBus,
        'timestamp': DateTime.now().toIso8601String()
      };

      await FirebaseDatabase.instance.ref('routeAlerts/route5').set(alertData);
      setState(() {
        _routeNotifyStatus = "✅ Route 5 buses notified successfully!";
      });
    } catch (e) {
      setState(() {
        _routeNotifyStatus = "âŒ Route notification failed: $e";
      });
    }
  }

  // Visual Speech monitor simulation engine
  void _startSpeechMonitor() {
    setState(() {
      _smActive = true;
      _driveSeconds = 0;
      _totalSpeakingSeconds = 0;
      _sessionsCount = 0;
      _longestSessionSeconds = 0;
      _speechUsagePercentage = 0;
      _speechLog = [];
      _showSpeechAlert = false;
      _isSpeaking = false;
      _currentSpeechSessionSecs = 0;
    });

    final random = Random();

    // Visual wave timer
    _waveTimer = Timer.periodic(const Duration(milliseconds: 150), (timer) {
      if (!mounted) return;
      if (_isSpeaking) {
        setState(() {
          _waveValues = List.generate(15, (index) => 4.0 + random.nextDouble() * 24.0);
        });
      } else {
        setState(() {
          _waveValues = List.filled(15, 2.0);
        });
      }
    });

    // Stats simulation tick (every 1s)
    _smSimulationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        _driveSeconds++;

        // 4% probability to toggle speech states to simulate conversation events
        if (random.nextDouble() < 0.05) {
          _isSpeaking = !_isSpeaking;
          if (_isSpeaking) {
            _sessionsCount++;
            _currentSpeechSessionSecs = 0;
            HapticFeedback.selectionClick();
          } else {
            // log completed session
            if (_currentSpeechSessionSecs >= 3) {
              final logTime = DateTime.now().toLocal().toString().split(' ')[1].substring(0, 8);
              _speechLog.insert(0, {
                'time': logTime,
                'text': "Speech session: ${_currentSpeechSessionSecs}s",
                'isWarn': "false"
              });
            }
          }
        }

        if (_isSpeaking) {
          _totalSpeakingSeconds++;
          _currentSpeechSessionSecs++;
          if (_currentSpeechSessionSecs > _longestSessionSeconds) {
            _longestSessionSeconds = _currentSpeechSessionSecs;
          }
        }

        if (_driveSeconds > 0) {
          _speechUsagePercentage = (_totalSpeakingSeconds / _driveSeconds) * 100;
        }

        if (_speechUsagePercentage > _warnThresholdPct && !_showSpeechAlert) {
          _showSpeechAlert = true;
          HapticFeedback.vibrate();
          _speechLog.insert(0, {
            'time': DateTime.now().toLocal().toString().split(' ')[1].substring(0, 8),
            'text': "âš ï¸ Speech warning: safety threshold exceeded!",
            'isWarn': "true"
          });
        }
      });
    });
  }

  void _stopSpeechMonitor() {
    _smSimulationTimer?.cancel();
    _waveTimer?.cancel();
    setState(() {
      _smActive = false;
      _isSpeaking = false;
      _waveValues = List.filled(15, 2.0);
    });
  }

  void _logBoarding() {
    if (_attendanceCount >= _attendanceCapacity) {
      _showDialog("Attendance", t('allBoarded'));
      return;
    }
    setState(() {
      _attendanceCount++;
    });
    _showSnackBar("🎓 Student boarding logged: $_attendanceCount / $_attendanceCapacity");
  }

  void _showSnackBar(String m) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(m, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF2563EB),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
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

  String _formatDuration(int secs) {
    final m = secs ~/ 60;
    final s = secs % 60;
    return "$m:${s.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _appStatus == "Offline"
        ? const Color(0xFF64748B)
        : (_appStatus == "Broken Down" ? const Color(0xFFDC2626) : const Color(0xFF2563EB));

    return Scaffold(
      backgroundColor: const Color(0xFFEEF2FF),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: const Center(child: Text("ðŸš", style: TextStyle(fontSize: 20))),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('appTitle'),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF1E3A8A)),
                ),
                Text(
                  t('appSubtitle'),
                  style: const TextStyle(fontSize: 9, color: Color(0xFF64748B), fontWeight: FontWeight.bold),
                ),
              ],
            )
          ],
        ),
        actions: [
          // Firebase Live Connection state badge
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _firebaseConnected ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _firebaseConnected ? const Color(0xFF86EFAC) : const Color(0xFFFCA5A5),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: _firebaseConnected ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _firebaseConnected ? "Live" : "Offline",
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    color: _firebaseConnected ? const Color(0xFF166534) : const Color(0xFF991B1B),
                  ),
                )
              ],
            ),
          )
        ],
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Bus Ready Banner spacing placeholder
                if (_showBusReadyBanner) const SizedBox(height: 80),
                // Driver metadata dashboard
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0xFFDBE2F8), width: 1.2),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t('dashboardLabel'),
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF64748B), letterSpacing: 1.0),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildPill(widget.driverBus, t('busLabel')),
                      _buildPill(_appStatus, t('statusLabel'), valueColor: statusColor),
                      _buildPill(t('routeLabel'), "Route 5"),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Firebase Synchronization strip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFDBEAFE), width: 1.2),
              ),
              child: Row(
                children: [
                  AnimatedRotation(
                    turns: _isSyncing ? 1.0 : 0.0,
                    duration: const Duration(seconds: 1),
                    child: const Icon(Icons.cloud_sync, color: Color(0xFF1E40AF), size: 20),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _syncStatusText,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF1E40AF)),
                    ),
                  ),
                  Text(
                    _syncTimestamp,
                    style: const TextStyle(fontSize: 10, color: Color(0xFF64748B), fontWeight: FontWeight.bold),
                  )
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Geolocation and GPS Tracking telemetry
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
                      Text(t('gpsLabel'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFF334155))),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: _isTracking ? const Color(0xFFEFF6FF) : const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _gpsStatus,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            color: _isTracking ? const Color(0xFF2563EB) : const Color(0xFF64748B),
                          ),
                        ),
                      )
                    ],
                  ),
                  const SizedBox(height: 16),
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
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t('highlightTitle'),
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF1E3A8A)),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          t('highlightText'),
                          style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), height: 1.4, fontWeight: FontWeight.w500),
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
                            backgroundColor: const Color(0xFF2563EB),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            elevation: 0,
                          ),
                          onPressed: _isTracking ? null : _startTracking,
                          child: Text(t('startTracking'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Color(0xFFDBE2F8)),
                            foregroundColor: const Color(0xFF1E293B),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                          ),
                          onPressed: _isTracking ? _stopTracking : null,
                          child: Text(t('stopTracking'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFDC2626),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      elevation: 0,
                    ),
                    onPressed: _isTracking && !_breakdownActive ? _reportBreakdown : null,
                    icon: const Icon(Icons.warning_amber, size: 16),
                    label: Text(t('reportBreakdown'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                  )
                ],
              ),
            ),
            const SizedBox(height: 16),

            // SPEECH MONITOR CARD
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFFFFDF5), Color(0xFFFEF3C7)],
                ),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: const Color(0xFFFCD34D).withValues(alpha: 0.5), width: 1.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFDE68A),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.center,
                        child: const Text("ðŸŽ™ï¸", style: TextStyle(fontSize: 18)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t('speechTitle'),
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: Color(0xFF92400E)),
                            ),
                            Text(
                              _smActive ? t('speechActive') : t('speechWaiting'),
                              style: const TextStyle(fontSize: 10, color: Color(0xFFB45309), fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _smActive ? const Color(0xFFDCFCE7) : const Color(0xFFE5E7EB),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: _smActive ? (_isSpeaking ? Colors.red : Colors.green) : Colors.grey,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _smActive ? (_isSpeaking ? "SPEAKING" : "LIVE") : "OFF",
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w900,
                                color: _smActive ? (_isSpeaking ? Colors.red : const Color(0xFF166534)) : Colors.grey,
                              ),
                            )
                          ],
                        ),
                      )
                    ],
                  ),
                  const SizedBox(height: 16),

                  if (!_smActive)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.2), width: 1, style: BorderStyle.solid),
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        "🔒 Monitoring activates automatically when tracking starts.",
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11, color: Color(0xFFB45309), fontWeight: FontWeight.bold),
                      ),
                    ),

                  if (_smActive) ...[
                    // Soundwave visualization bounce bar
                    Center(
                      child: SizedBox(
                        height: 36,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: _waveValues.map((h) {
                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              width: 3.5,
                              height: h,
                              margin: const EdgeInsets.symmetric(horizontal: 1.5),
                              decoration: BoxDecoration(
                                color: _isSpeaking ? const Color(0xFFEF4444) : const Color(0xFFD97706),
                                borderRadius: BorderRadius.circular(999),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Grid stats
                    GridView.count(
                      crossAxisCount: 2,
                      shrinkWrap: true,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      childAspectRatio: 2.1,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        _buildSmTile(t('speakingTime'), _formatDuration(_totalSpeakingSeconds)),
                        _buildSmTile(t('sessions'), _sessionsCount.toString()),
                        _buildSmTile(t('longest'), _formatDuration(_longestSessionSeconds)),
                        _buildSmTile(t('pctDrive'), "${_speechUsagePercentage.toStringAsFixed(0)}%"),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Speech progress bar
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(t('speechUsage'), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF92400E))),
                            Text("${_speechUsagePercentage.toStringAsFixed(0)}% / 20%", style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF92400E))),
                          ],
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: LinearProgressIndicator(
                            value: (_speechUsagePercentage / 100).clamp(0.0, 1.0),
                            backgroundColor: const Color(0xFFFDE68A),
                            color: _speechUsagePercentage > _warnThresholdPct ? const Color(0xFFEF4444) : const Color(0xFFF59E0B),
                            minHeight: 8,
                          ),
                        ),
                      ],
                    ),

                    if (_showSpeechAlert) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEE2E2),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFFCA5A5), width: 1.2),
                        ),
                        child: Row(
                          children: [
                            const Text("âš ï¸", style: TextStyle(fontSize: 18)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                t('speechTooMuch'),
                                style: const TextStyle(fontSize: 11, color: Color(0xFF991B1B), fontWeight: FontWeight.w900),
                              ),
                            )
                          ],
                        ),
                      ),
                    ],

                    if (_speechLog.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Text(t('sessionLog'), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF92400E))),
                      const SizedBox(height: 6),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 90),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.all(8),
                          itemCount: _speechLog.length > 5 ? 5 : _speechLog.length,
                          itemBuilder: (context, idx) {
                            final item = _speechLog[idx];
                            final isWarn = item['isWarn'] == "true";
                            return Container(
                              margin: const EdgeInsets.only(bottom: 4),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                border: Border(left: BorderSide(color: isWarn ? Colors.red : const Color(0xFFF59E0B), width: 3)),
                              ),
                              child: Row(
                                children: [
                                  Text(
                                    item['time'] ?? "",
                                    style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFFB45309)),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      item['text'] ?? "",
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: isWarn ? Colors.red : const Color(0xFF78350F),
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  )
                                ],
                              ),
                            );
                          },
                        ),
                      )
                    ]
                  ]
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Fleet Analytics dashboard
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
                  Text(t('fleetLabel'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFF334155))),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      // Geofence & Next Stop card
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FBFF),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: const Color(0xFFDBE2F8)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEFF6FF),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Text("On route", style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Color(0xFF2563EB))),
                              ),
                              const SizedBox(height: 8),
                              Text(t('etaTitle'), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A))),
                              const SizedBox(height: 2),
                              Text("${t('nextStopLabel')} $_nextStop", style: const TextStyle(fontSize: 9, color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
                              const SizedBox(height: 6),
                              Text(_eta, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF2563EB))),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Vehicle Health Card
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8FBFF),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: const Color(0xFFDBE2F8)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFEF3C7),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Text("Maintenance", style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Color(0xFFD97706))),
                              ),
                              const SizedBox(height: 8),
                              Text(t('healthTitle'), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A))),
                              const SizedBox(height: 6),
                              const Text("Next service in 4 days", style: TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.w600, height: 1.4)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Student Boarding Card
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FBFF),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFFDBE2F8)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t('boardingTitle'), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A))),
                            const SizedBox(height: 4),
                            Text("$_attendanceCount / $_attendanceCapacity boarded", style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
                          ],
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: const Color(0xFF1E293B),
                            side: const BorderSide(color: Color(0xFFDBE2F8)),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            elevation: 0,
                          ),
                          onPressed: _logBoarding,
                          child: Text(t('logBoarding'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                        )
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Live Leaflet style map centered on driver location
            _buildMapCard(),
            const SizedBox(height: 16),

            // Breakdown Alert Panel
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
                      hintText: "e.g. BUS202",
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(t('detectedLocation'), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
                      Text(
                        _isTracking ? "${_latitude.toStringAsFixed(4)}, ${_longitude.toStringAsFixed(4)}" : t('locationUnavailable'),
                        style: const TextStyle(fontSize: 11, color: Color(0xFF0F172A), fontWeight: FontWeight.bold),
                      )
                    ],
                  ),
                  const SizedBox(height: 14),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFDC2626),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      elevation: 0,
                    ),
                    onPressed: _sendBreakdownAlert,
                    child: Text(t('sendAlert'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                  )
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Route buses notification card
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFEF2F2), Color(0xFFFEE2E2)],
                ),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: const Color(0xFFFCA5A5).withValues(alpha: 0.5), width: 1.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Text("🚌", style: TextStyle(fontSize: 20)),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(t('notifyRoute'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF991B1B))),
                          Text(t('autoAlertNearby'), style: const TextStyle(fontSize: 9, color: Color(0xFFB45309), fontWeight: FontWeight.bold)),
                        ],
                      )
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    t('notifyExpl'),
                    style: const TextStyle(fontSize: 11, color: Color(0xFF78350F), height: 1.4, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 14),
                  // List of route buses
                  Column(
                    children: [
                      _buildRouteBusItem("BUS102", "Route 5 · Behind you ~2.4 km"),
                      _buildRouteBusItem("BUS105", "Route 5 · Ahead ~1.1 km"),
                      _buildRouteBusItem("BUS108", "Route 7 · Different route", isDiffRoute: true),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFDC2626),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      elevation: 0,
                    ),
                    onPressed: _notifyRouteBusesEnabled ? _sendBreakdownToRouteBuses : null,
                    child: Text(t('sendBreakdownBuses'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                  ),
                  if (_routeNotifyStatus.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _routeNotifyStatus,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF166534)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Settings language selector & Logout controls
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0xFFDBE2F8)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t('langLabelDash'), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF334155))),
                      const SizedBox(height: 6),
                      DropdownButton<String>(
                        value: widget.currentLang,
                        underline: const SizedBox(),
                        style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF2563EB), fontSize: 13),
                        items: const [
                          DropdownMenuItem(value: 'en', child: Text('English')),
                          DropdownMenuItem(value: 'ta', child: Text('தமிழ் stop')),
                          DropdownMenuItem(value: 'te', child: Text('తెలుగు stop')),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            widget.onLanguageChanged(val);
                          }
                        },
                      )
                    ],
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFF1F5F9),
                      foregroundColor: const Color(0xFF1E293B),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      elevation: 0,
                    ),
                    onPressed: widget.onLogout,
                    child: Text(t('logout'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  )
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Back role switcher
            TextButton(
              onPressed: widget.onSwitchRole,
              child: const Text(
                "🎓 Switch to Student Mode",
                style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF2563EB)),
              ),
            ),
            const SizedBox(height: 8),

            // Footer
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
          // Bus Ready Banner overlay — auto-dismisses after 10 seconds
          AnimatedPositioned(
            duration: const Duration(milliseconds: 500),
            curve: Curves.fastOutSlowIn,
            top: _showBusReadyBanner ? 16 : -160,
            left: 16,
            right: 16,
            child: Material(
              color: Colors.transparent,
              elevation: 12,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF16A34A), Color(0xFF15803D)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF16A34A).withValues(alpha: 0.35),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          alignment: Alignment.center,
                          child: const Text("ðŸš", style: TextStyle(fontSize: 24)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                "BUS IS READY!",
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w900,
                                  color: Colors.white70,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                "${widget.driverBus} — GPS Tracking Active",
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w900,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 2),
                              const Text(
                                "Students have been notified. Drive safe! ðŸ™",
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.white70,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              _showBusReadyBanner = false;
                            });
                            _busReadyTimer?.cancel();
                            _busReadyCountdownTimer?.cancel();
                          },
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            alignment: Alignment.center,
                            child: const Icon(Icons.close, color: Colors.white, size: 16),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: LinearProgressIndicator(
                              value: _busReadyCountdown / 10.0,
                              backgroundColor: Colors.white.withValues(alpha: 0.2),
                              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                              minHeight: 4,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          "${_busReadyCountdown}s",
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPill(String value, String label, {Color? valueColor}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FBFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFDBE2F8)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: valueColor ?? const Color(0xFF0F172A)),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 9, color: Color(0xFF64748B), fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildFieldTile(String label, String val) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FBFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFDBE2F8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: const TextStyle(fontSize: 9, color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(val, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
        ],
      ),
    );
  }

  Widget _buildSmTile(String label, String val) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF92400E))),
          const SizedBox(height: 2),
          Text(val, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFFB45309))),
        ],
      ),
    );
  }

  Widget _buildRouteBusItem(String busId, String meta, {bool isDiffRoute = false}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFCA5A5).withValues(alpha: 0.15)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(busId, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF1E293B))),
              const SizedBox(height: 2),
              Text(meta, style: const TextStyle(fontSize: 9, color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
            ],
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isDiffRoute ? const Color(0xFFFEE2E2) : const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              isDiffRoute ? "Diff Route" : "Same Route",
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w900,
                color: isDiffRoute ? const Color(0xFFB91C1C) : const Color(0xFF1D4ED8),
              ),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildMapCard() {
    if (_currentPosition == null) {
      return Container(
        height: 310,
        decoration: BoxDecoration(
          color: const Color(0xFFDBEAFE),
          borderRadius: BorderRadius.circular(28),
        ),
        alignment: Alignment.center,
        child: const Text(
          "Map will appear once tracking begins.",
          style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1E3A8A)),
        ),
      );
    }
    final latLng = LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
    return Container(
      height: 310,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFFDBE2F8), width: 1.5),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: latLng,
            initialZoom: 15,
          ),
          children: [
            TileLayer(
              urlTemplate: "https://mt1.google.com/vt/lyrs=m&x={x}&y={y}&z={z}",
              subdomains: const ['a', 'b', 'c'],
            ),
            MarkerLayer(
              markers: [
                Marker(
                  point: latLng,
                  width: 40,
                  height: 40,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF2563EB),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2.5),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 6,
                          offset: Offset(0, 3),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: const Text("🚌", style: TextStyle(fontSize: 20)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class StudentBreakdownNotificationsPage extends StatelessWidget {
  final bool breakdownActive;
  final String busId;
  final String replacement;

  const StudentBreakdownNotificationsPage({
    super.key,
    required this.breakdownActive,
    required this.busId,
    required this.replacement,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEEF2FF),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          "Notifications",
          style: TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF0F172A), fontSize: 16),
        ),
        iconTheme: const IconThemeData(color: Color(0xFF0F172A)),
      ),
      body: !breakdownActive
          ? const Center(
              child: Text(
                "No notifications yet",
                style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16.0),
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF2F2),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFFCA5A5)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.03),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("🚨", style: TextStyle(fontSize: 24)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "Bus $busId Breakdown Alert",
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF991B1B),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              replacement == "Pending"
                                  ? "Bus $busId breakdown reported. Replacement Bus dispatch is pending. Stay at your stop."
                                  : "Bus $busId breakdown. Replacement Bus $replacement dispatched. Stay at your stop.",
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF7F1D1D),
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Color(0xFF991B1B), size: 20),
                        onPressed: () {
                          if (Firebase.apps.isNotEmpty) {
                            FirebaseDatabase.instance.ref('breakdowns/$busId').remove();
                          }
                          Navigator.pop(context);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
