import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'driver_login_screen.dart';
import 'driver_dashboard.dart';

class DriverShell extends StatefulWidget {
  final VoidCallback onSwitchRole;
  final String currentLang;
  final Function(String) onLanguageChanged;
  const DriverShell({
    super.key,
    required this.onSwitchRole,
    required this.currentLang,
    required this.onLanguageChanged,
  });

  @override
  State<DriverShell> createState() => _DriverShellState();
}

class _DriverShellState extends State<DriverShell> {
  bool _isLoggedIn = false;
  String _driverBus = "";

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  void _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
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

  @override
  Widget build(BuildContext context) {
    if (!_isLoggedIn) {
      return DriverLoginScreen(
        currentLang: widget.currentLang,
        onLogin: _login,
        onLanguageChanged: widget.onLanguageChanged,
        onSwitchRole: widget.onSwitchRole,
      );
    } else {
      return DriverDashboard(
        driverBus: _driverBus,
        currentLang: widget.currentLang,
        onLogout: _logout,
        onLanguageChanged: widget.onLanguageChanged,
        onSwitchRole: widget.onSwitchRole,
      );
    }
  }
}
