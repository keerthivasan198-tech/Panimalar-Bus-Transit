class LogEntry {
  final double id;
  final String bus;
  final String driver;
  final String route;
  final String date;
  String? arrived;
  String? departed;
  String status; // arrived, delayed, on-route

  LogEntry({
    required this.id,
    required this.bus,
    required this.driver,
    required this.route,
    required this.date,
    this.arrived,
    this.departed,
    required this.status,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'bus': bus,
    'driver': driver,
    'route': route,
    'date': date,
    'arrived': arrived,
    'departed': departed,
    'status': status,
  };

  factory LogEntry.fromJson(Map<String, dynamic> json) => LogEntry(
    id: (json['id'] as num).toDouble(),
    bus: json['bus'] ?? '',
    driver: json['driver'] ?? '',
    route: json['route'] ?? '',
    date: json['date'] ?? '',
    arrived: json['arrived'],
    departed: json['departed'],
    status: json['status'] ?? 'on-route',
  );
}
