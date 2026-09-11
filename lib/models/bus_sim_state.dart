class BusSimState {
  double progress;
  double lat;
  double lng;
  double speed;
  bool near;

  BusSimState({
    required this.progress,
    required this.lat,
    required this.lng,
    required this.speed,
    required this.near,
  });
}
