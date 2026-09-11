class RouteEntry {
  final double id;
  final String key;
  final String name;
  final List<String> stops;
  final String color;

  RouteEntry({
    required this.id,
    required this.key,
    required this.name,
    required this.stops,
    required this.color,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'key': key,
    'name': name,
    'stops': stops,
    'color': color,
  };

  factory RouteEntry.fromJson(Map<String, dynamic> json) => RouteEntry(
    id: (json['id'] is num)
        ? (json['id'] as num).toDouble()
        : (double.tryParse(json['id']?.toString() ?? '') ?? 0.0),
    key: json['key']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    stops: json['stops'] is List ? List<String>.from((json['stops'] as List).map((s) => s.toString())) : [],
    color: json['color']?.toString() ?? '#2563EB',
  );
}
