class UploadEntry {
  final String name;
  final String size;

  UploadEntry({required this.name, required this.size});

  Map<String, dynamic> toJson() => {'name': name, 'size': size};
  factory UploadEntry.fromJson(Map<String, dynamic> json) => UploadEntry(
    name: json['name'] ?? '',
    size: json['size'] ?? '',
  );
}
