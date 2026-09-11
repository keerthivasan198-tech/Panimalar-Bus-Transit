class AlertEntry {
  final double id;
  final String type; // breakdown, delay, route
  final String bus;  // bus number or 'all'
  final String msg;
  final String time;

  AlertEntry({
    required this.id,
    required this.type,
    required this.bus,
    required this.msg,
    required this.time,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'bus': bus,
    'msg': msg,
    'time': time,
  };

  factory AlertEntry.fromJson(Map<String, dynamic> json) => AlertEntry(
    id: (json['id'] as num).toDouble(),
    type: json['type'] ?? 'delay',
    bus: json['bus'] ?? 'all',
    msg: json['msg'] ?? '',
    time: json['time'] ?? '',
  );
}
