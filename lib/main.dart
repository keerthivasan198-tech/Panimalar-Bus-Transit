import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'screens/admin/admin_shell.dart';
import 'screens/driver/driver_shell.dart';
import 'main1.dart' as student_app;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    debugPrint("Failed to load .env file: $e");
  }
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
      home: const RoleSelectionScreen(),
    );
  }
}

class RoleSelectionScreen extends StatelessWidget {
  const RoleSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header Section
              Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 5),
                        )
                      ],
                    ),
                    child: Image.asset(
                      'assets/images/panimalar_logo.png',
                      height: 60,
                      width: 60,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'PANIMALAR ENGINEERING COLLEGE',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1E3A8A),
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'College Administration System',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF64748B),
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Select Portal Access',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF334155),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              
              // Cards Section
              Expanded(
                child: LayoutBuilder(
                  builder: (context, cardConstraints) {
                    final isWide = cardConstraints.maxWidth > 600;
                    
                    final adminCard = _buildRoleCard(
                      context,
                      title: 'Admin Portal',
                      subtitle: 'Manage fleet, routes & communications',
                      imagePath: 'assets/images/college_admin.jpg',
                      icon: Icons.admin_panel_settings,
                      color: const Color(0xFF2563EB),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (context) => const AdminAppShell()),
                        );
                      },
                    );

                    final driverCard = _buildRoleCard(
                      context,
                      title: 'Driver Portal',
                      subtitle: 'Live navigation & student boarding',
                      imagePath: 'assets/images/bus_driver.jpg',
                      icon: Icons.directions_bus,
                      color: const Color(0xFF16A34A),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (context) => const DriverAppShell()),
                        );
                      },
                    );

                    if (isWide) {
                      return Row(
                        children: [
                          Expanded(child: adminCard),
                          const SizedBox(width: 24),
                          Expanded(child: driverCard),
                        ],
                      );
                    }
                    return Column(
                      children: [
                        Expanded(child: adminCard),
                        const SizedBox(height: 16),
                        Expanded(child: driverCard),
                      ],
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

  Widget _buildRoleCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required String imagePath,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.2),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Image Section (Covers Entire Card)
                Image.asset(
                  imagePath,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      color: Colors.grey[300],
                      child: const Icon(Icons.image_not_supported, color: Colors.grey),
                    );
                  },
                ),
                // Gradient Overlay
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.2),
                        Colors.black.withValues(alpha: 0.9),
                      ],
                      stops: const [0.0, 0.4, 1.0],
                    ),
                  ),
                ),
                // Text Overlay Section
                Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: color,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(icon, color: Colors.white, size: 24),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              title,
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w900,
                                color: Colors.white,
                                shadows: [
                                  Shadow(color: Colors.black45, blurRadius: 4, offset: Offset(0, 2))
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Text(
                            'Access Portal',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(Icons.arrow_forward, size: 16, color: Colors.white),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AdminAppShell extends StatefulWidget {
  const AdminAppShell({super.key});

  @override
  State<AdminAppShell> createState() => _AdminAppShellState();
}

class _AdminAppShellState extends State<AdminAppShell> {
  String _currentLang = "ta";
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLang = prefs.getString("admin_user_lang") ?? "ta";
    setState(() {
      _currentLang = savedLang;
      _isLoading = false;
    });
  }

  void _updateLang(String lang) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("admin_user_lang", lang);
    setState(() {
      _currentLang = lang;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }
    return AdminShell(
      onSwitchRole: () {
        Navigator.pop(context);
      },
      currentLang: _currentLang, 
      onLanguageChanged: _updateLang
    );
  }
}

class DriverAppShell extends StatefulWidget {
  const DriverAppShell({super.key});

  @override
  State<DriverAppShell> createState() => _DriverAppShellState();
}

class _DriverAppShellState extends State<DriverAppShell> {
  String _currentLang = "ta";
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLang = prefs.getString("driver_user_lang") ?? "ta";
    setState(() {
      _currentLang = savedLang;
      _isLoading = false;
    });
  }

  void _updateLang(String lang) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("driver_user_lang", lang);
    setState(() {
      _currentLang = lang;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }
    return DriverShell(
      onSwitchRole: () {
        Navigator.pop(context);
      },
      currentLang: _currentLang, 
      onLanguageChanged: _updateLang
    );
  }
}

class StudentAppShell extends StatelessWidget {
  const StudentAppShell({super.key});

  @override
  Widget build(BuildContext context) {
    return student_app.MainShell(
      onSwitchRole: () {
        Navigator.pop(context);
      },
    );
  }
}
