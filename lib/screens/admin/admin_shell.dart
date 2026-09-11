import 'package:flutter/material.dart';
import 'admin_dashboard.dart';

class AdminShell extends StatefulWidget {
  final VoidCallback onSwitchRole;
  final String currentLang;
  final Function(String) onLanguageChanged;
  const AdminShell({
    super.key,
    required this.onSwitchRole,
    required this.currentLang,
    required this.onLanguageChanged,
  });

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  bool _isLoggedIn = false;
  bool _obscurePassword = true;
  final TextEditingController _passCtrl = TextEditingController();

  void _login() {
    if (_passCtrl.text == "admin123") {
      setState(() {
        _isLoggedIn = true;
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("❌ Invalid Admin Password!")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isLoggedIn) {
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
            child: Stack(
              children: [
                Center(
                  child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                  elevation: 8,
                  shadowColor: const Color(0xFF2563EB).withValues(alpha: 0.1),
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Icon(Icons.admin_panel_settings, size: 64, color: Color(0xFF2563EB)),
                        const SizedBox(height: 16),
                        const Text(
                          "Admin Console",
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF1E3A8A)),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          "Enter password to access administration features",
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                        ),
                        const SizedBox(height: 24),
                        TextField(
                          controller: _passCtrl,
                          obscureText: _obscurePassword,
                          decoration: InputDecoration(
                            hintText: "Admin Password",
                            prefixIcon: const Icon(Icons.lock, size: 18),
                            suffixIcon: IconButton(
                              icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility, size: 18),
                              onPressed: () {
                                setState(() {
                                  _obscurePassword = !_obscurePassword;
                                });
                              },
                            ),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(30)),
                          ),
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF2563EB),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                          ),
                          onPressed: _login,
                          child: const Text("Enter Dashboard", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                            side: const BorderSide(color: Color(0xFFCBD5E1)),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: widget.onSwitchRole,
                          child: const Text("Back to Selection", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF475569))),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
                ),
                Positioned(
                  top: 10,
                  right: 10,
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Color(0xFF1E3A8A), size: 28),
                    onPressed: widget.onSwitchRole,
                    tooltip: 'Exit',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return AdminDashboard(
      onSwitchRole: widget.onSwitchRole,
      currentLang: widget.currentLang,
      onLanguageChanged: widget.onLanguageChanged,
    );
  }
}
