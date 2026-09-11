// ============================================================
// app_config.dart - Centralized App Configuration
// ============================================================
// All sensitive URLs and keys are stored here.
// The actual secret values (MongoDB URI, API keys) should be
// placed in the .env file at the project root. Never commit
// .env to version control.
// ============================================================

class AppConfig {
  AppConfig._(); // Private constructor - use static members only

  // ---- Firebase ----
  // These values come from Firebase Console -> Project Settings -> Web App
  static const String firebaseApiKey =
      'AIzaSyBUozEQcU48yRBSSM3EquhV8Sm1vWtRPFY';
  static const String firebaseAppId =
      '1:538185362536:web:e8d35e63d4c641979c1fdd';
  static const String firebaseMessagingSenderId = '538185362536';
  static const String firebaseProjectId = 'gen-lang-client-0636615491';
  static const String firebaseDatabaseUrl =
      'https://gen-lang-client-0636615491-default-rtdb.asia-southeast1.firebasedatabase.app';

  // ---- Backend REST API ----
  // The Node.js/Express backend hosted on Render.com
  // Update this URL if the backend is deployed elsewhere.
  static const String apiBaseUrl = 'https://panimalr-bus.onrender.com';

  // Derived API endpoints
  static String studentsEndpoint(String rollNo) =>
      '$apiBaseUrl/api/students/$rollNo';
  static const String voiceUploadEndpoint = '$apiBaseUrl/api/voice';
  static String voiceDeleteEndpoint(String mongoId) =>
      '$apiBaseUrl/api/voice/$mongoId';

  // ---- Mapping & Routing ----
  // Open-source OSRM routing for walking directions on campus map
  static const String osrmRoutingUrl =
      'https://router.project-osrm.org/route/v1/foot/';

  // CartoDB basemap tiles (free, no API key needed)
  static const String mapTileUrl =
      'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png';
  static const String mapTileSubdomains = 'abcd';

  // ---- App Metadata ----
  static const String appName = 'Panimalar Smart Transit';
  static const String collegeName = 'Panimalar Engineering College';
}
