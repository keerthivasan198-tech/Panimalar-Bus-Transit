class DriverEntry {
  final double id;
  final String bus;
  final String driver;
  final String route;
  final String type; // boys, girls, combined

  DriverEntry({
    required this.id,
    required this.bus,
    required this.driver,
    required this.route,
    required this.type,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'bus': bus,
    'driver': driver,
    'route': route,
    'type': type,
  };

  factory DriverEntry.fromJson(Map<String, dynamic> json) => DriverEntry(
    id: (json['id'] is num)
        ? (json['id'] as num).toDouble()
        : (double.tryParse(json['id']?.toString() ?? '') ?? 0.0),
    bus: json['bus']?.toString() ?? '',
    driver: json['driver']?.toString() ?? '',
    route: json['route']?.toString() ?? '',
    type: json['type']?.toString() ?? 'combined',
  );
}
