import 'dart:math';
import 'package:latlong2/latlong.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Panimalar Engineering College — Campus Road Network Graph
//
// Coordinates are placed on the ROAD CENTRELINES visible in the campus map
// (the same roads Google Maps shows: CSBS Ln, CSE Ln, perimeter road, etc.)
//
// Road network layout (from satellite / Google Maps imagery):
//
//   • PERIMETER ROAD  — runs along the west edge of campus, roughly N-S
//   • CSE LANE        — runs E-W through the southern academic block
//   • CSBS LANE       — runs E-W through the middle academic block
//   • NORTH ROAD      — connects IT / Mech / EEE blocks at the north end
//   • CROSS ROADS     — short connecting segments between the above
//
// Dijkstra on this graph gives the shortest ROAD path between any two points.
// ─────────────────────────────────────────────────────────────────────────────

class _Node {
  final String id;
  final LatLng pos;
  const _Node(this.id, this.pos);
}

// ── Road junction / waypoint nodes ───────────────────────────────────────────
// Named after their approximate position on the campus road grid.
// Coordinates were manually read off the Google Maps satellite view.

final _nodes = <_Node>[
  // ── Main Entrance & south entry road (Longitude: 80.07520) ───────────────
  _Node('gate',         const LatLng(13.04723, 80.07520)),
  _Node('gate_n',       const LatLng(13.04790, 80.07520)),
  _Node('admin_jct',    const LatLng(13.04885, 80.07520)),

  // ── CSE Lane (Latitude: 13.04960) ─────────────────────────────────────────
  _Node('cse_w',        const LatLng(13.04960, 80.07465)),
  _Node('cse_jct',      const LatLng(13.04960, 80.07520)),
  _Node('cse_e',        const LatLng(13.04960, 80.07650)),

  // ── AIDS / East Lane (Longitude: 80.07650) ────────────────────────────────
  _Node('aids_jct',     const LatLng(13.04980, 80.07650)),
  _Node('east_lane_mid',const LatLng(13.05075, 80.07650)),

  // ── Central Spine Road (Longitude: 80.07520) ──────────────────────────────
  _Node('spine_a',      const LatLng(13.05020, 80.07520)),
  _Node('spine_b',      const LatLng(13.05085, 80.07520)),
  _Node('spine_c',      const LatLng(13.05100, 80.07520)),
  _Node('spine_d',      const LatLng(13.05130, 80.07520)),
  _Node('spine_e',      const LatLng(13.05172, 80.07520)),

  // ── CSBS Lane (Latitude: 13.05172) ────────────────────────────────────────
  _Node('csbs_w',       const LatLng(13.05172, 80.07520)),
  _Node('csbs_mid',     const LatLng(13.05172, 80.07575)),
  _Node('csbs_jct',     const LatLng(13.05172, 80.07600)),
  _Node('csbs_e',       const LatLng(13.05172, 80.07650)),

  // ── Upper Central Road (Longitude: 80.07520) ──────────────────────────────
  _Node('mid_n1',       const LatLng(13.05240, 80.07520)),
  _Node('mid_n2',       const LatLng(13.05310, 80.07520)),
  _Node('mess2_jct',    const LatLng(13.05352, 80.07520)),
  _Node('mba_jct',      const LatLng(13.05391, 80.07520)),

  // ── IT / North Road (Longitude: 80.07340) ─────────────────────────────────
  _Node('it_road_s',    const LatLng(13.05340, 80.07340)),
  _Node('it_jct',       const LatLng(13.05348, 80.07340)),
  _Node('north_jct',    const LatLng(13.05410, 80.07340)),

  // ── EEE / Mech (North End) ────────────────────────────────────────────────
  _Node('eee_road',     const LatLng(13.05459, 80.07340)),
  _Node('eee_jct',      const LatLng(13.05459, 80.07270)),
  _Node('mech_jct',     const LatLng(13.05474, 80.07270)),

  // ── Mess-1 (Latitude: 13.05085) ───────────────────────────────────────────
  _Node('mess1_jct',    const LatLng(13.05085, 80.07470)),
];

// ── Road edges (bidirectional) ────────────────────────────────────────────────
// Each pair [A, B] represents a direct road segment between node A and node B.
final _edges = [
  // Entry road
  ['gate',      'gate_n'],
  ['gate_n',    'admin_jct'],

  // Admin → CSE spine
  ['admin_jct', 'cse_jct'],
  ['admin_jct', 'cse_w'],

  // CSE Lane (E-W)
  ['cse_w',     'cse_jct'],
  ['cse_jct',   'cse_e'],
  ['cse_e',     'aids_jct'],

  // Spine road (N-S through campus centre)
  ['cse_w',     'spine_a'],
  ['cse_jct',   'spine_a'],
  ['spine_a',   'spine_b'],
  ['spine_b',   'spine_c'],
  ['spine_c',   'spine_d'],
  ['spine_d',   'spine_e'],

  // ECE off spine
  ['spine_c',   'spine_c'], // ECE is on spine_c

  // Mess-1 spur
  ['spine_b',   'mess1_jct'],

  // CSBS Lane (E-W)
  ['spine_e',   'csbs_mid'],
  ['csbs_mid',  'csbs_jct'],
  ['csbs_jct',  'csbs_e'],

  // Spine continues north
  ['spine_e',   'mid_n1'],
  ['mid_n1',    'mid_n2'],
  ['mid_n2',    'mess2_jct'],
  ['mess2_jct', 'mba_jct'],

  // IT road
  ['mid_n1',    'it_road_s'],
  ['it_road_s', 'it_jct'],
  ['it_jct',    'north_jct'],

  // EEE / Mech
  ['north_jct', 'eee_road'],
  ['eee_road',  'eee_jct'],
  ['eee_jct',   'mech_jct'],

  // Cross-connects
  ['csbs_e',    'mid_n2'],   // east side cross road
  ['mba_jct',   'it_road_s'],
  
  // Eastern lane (N-S)
  ['aids_jct',  'east_lane_mid'],
  ['east_lane_mid', 'csbs_e'],
];

// ── Building snap: each CampusPoint name → nearest road node ─────────────────
const _buildingSnap = <String, String>{
  'Main Entrance Gate':       'gate',
  'Admin / Admission Block':  'admin_jct',
  'CSE Department':           'cse_jct',
  'AIDS (AI & Data Sci.)':    'aids_jct',
  'ECE Department':           'spine_c',
  'EEE Department':           'eee_jct',
  'IT Department':            'it_jct',
  'CSBS Department':          'csbs_jct',
  'Mechanical Dept.':         'mech_jct',
  'MBA Block':                'mba_jct',
  'Mess 1 (Main Mess)':       'mess1_jct',
  'Mess 2 (Hostel Mess)':     'mess2_jct',
};

// ─────────────────────────────────────────────────────────────────────────────
// Graph + Dijkstra
// ─────────────────────────────────────────────────────────────────────────────

class CampusPathGraph {
  late final Map<String, _Node> _nodeMap;
  late final Map<String, List<String>> _adj;

  CampusPathGraph() {
    _nodeMap = {for (final n in _nodes) n.id: n};
    _adj = {};
    for (final n in _nodes) {
      _adj[n.id] = [];
    }

    for (final e in _edges) {
      final a = e[0], b = e[1];
      if (a == b) continue; // skip self-loops
      if (!_adj.containsKey(a) || !_adj.containsKey(b)) continue;
      if (!_adj[a]!.contains(b)) _adj[a]!.add(b);
      if (!_adj[b]!.contains(a)) _adj[b]!.add(a);
    }
  }

  double _dist(LatLng a, LatLng b) {
    const r = 6371000.0;
    final p1 = a.latitude  * (pi / 180);
    final p2 = b.latitude  * (pi / 180);
    final dp = (b.latitude  - a.latitude)  * (pi / 180);
    final dl = (b.longitude - a.longitude) * (pi / 180);
    final x  = sin(dp / 2) * sin(dp / 2) +
               cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2);
    return r * 2 * atan2(sqrt(x), sqrt(1 - x));
  }

  /// Snap an arbitrary LatLng to the nearest road node.
  String _snap(LatLng pos) {
    String best = _nodes.first.id;
    double bestD = double.infinity;
    for (final n in _nodes) {
      final d = _dist(pos, n.pos);
      if (d < bestD) { bestD = d; best = n.id; }
    }
    return best;
  }

  /// Snap a building name to its designated road node (or nearest if unknown).
  String _snapBuilding(String name, LatLng fallback) =>
      _buildingSnap[name] ?? _snap(fallback);

  /// Dijkstra shortest path on the road graph.
  /// Returns ordered [LatLng] list from [origin] to [destination].
  /// Falls back to [origin, destination] straight line if no path exists.
  List<LatLng> shortestPath(LatLng origin, LatLng destination,
      {String? destName}) {
    final startId = _snap(origin);
    final endId   = destName != null
        ? _snapBuilding(destName, destination)
        : _snap(destination);

    if (startId == endId) return [origin, destination];

    final dist = <String, double>{
      for (final n in _nodes) n.id: double.infinity,
    };
    final prev = <String, String?>{for (final n in _nodes) n.id: null};
    dist[startId] = 0;

    final unvisited = <String>{for (final n in _nodes) n.id};

    while (unvisited.isNotEmpty) {
      // pick unvisited node with smallest tentative dist
      String? u;
      double minD = double.infinity;
      for (final id in unvisited) {
        if (dist[id]! < minD) { minD = dist[id]!; u = id; }
      }
      if (u == null || u == endId) break;
      unvisited.remove(u);

      for (final v in (_adj[u] ?? [])) {
        if (!unvisited.contains(v)) continue;
        final alt = dist[u]! + _dist(_nodeMap[u]!.pos, _nodeMap[v]!.pos);
        if (alt < dist[v]!) {
          dist[v] = alt;
          prev[v] = u;
        }
      }
    }

    // Reconstruct
    final ids = <String>[];
    String? cur = endId;
    while (cur != null) { ids.add(cur); cur = prev[cur]; }
    final ordered = ids.reversed.toList();

    if (ordered.isEmpty || ordered.first != startId) {
      return [origin, destination]; // fallback
    }

    // Build polyline: real GPS origin → road nodes → real GPS destination
    final pts = <LatLng>[origin];
    for (final id in ordered) {
      pts.add(_nodeMap[id]!.pos);
    }
    pts.add(destination);
    return pts;
  }

  /// Total road distance (metres) along a polyline.
  double pathDistanceM(List<LatLng> pts) {
    double total = 0;
    for (int i = 0; i < pts.length - 1; i++) {
      total += _dist(pts[i], pts[i + 1]);
    }
    return total;
  }
}

/// Singleton — build once, reuse everywhere.
final campusPathGraph = CampusPathGraph();
