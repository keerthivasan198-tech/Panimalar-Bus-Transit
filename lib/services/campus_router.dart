import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Fetches a real walking route between two coordinates using the free
/// OSRM demo server (OpenStreetMap road data — no API key required).
///
/// Returns the list of [LatLng] waypoints that follow actual paths/roads.
/// Falls back to a straight two-point line if the request fails.
class CampusRouter {
  // OSRM public demo server — foot profile for walking
  static const String _baseUrl = 'https://router.project-osrm.org/route/v1/foot';

  /// Get a walking route from [origin] to [destination].
  /// Returns a list of [LatLng] points forming the road-following path.
  static Future<List<LatLng>> getRoute(LatLng origin, LatLng destination) async {
    try {
      // OSRM format: /route/v1/{profile}/{lng,lat};{lng,lat}
      final url = Uri.parse(
        '$_baseUrl/'
        '${origin.longitude},${origin.latitude};'
        '${destination.longitude},${destination.latitude}'
        '?overview=full&geometries=geojson&steps=false',
      );

      final response = await http.get(url).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        return _fallback(origin, destination);
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final code = data['code'] as String?;
      if (code != 'Ok') return _fallback(origin, destination);

      final routes = data['routes'] as List?;
      if (routes == null || routes.isEmpty) return _fallback(origin, destination);

      // GeoJSON coordinates are [lng, lat] pairs
      final coords = (routes[0]['geometry']['coordinates'] as List)
          .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
          .toList();

      return coords.isNotEmpty ? coords : _fallback(origin, destination);
    } catch (_) {
      return _fallback(origin, destination);
    }
  }

  static List<LatLng> _fallback(LatLng origin, LatLng destination) =>
      [origin, destination];
}
