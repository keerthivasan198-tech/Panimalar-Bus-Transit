void main() {
  final str1 = 'SRI PADMAVATHY MAHAL (12.919 80.089)';
  final str2 = 'SRI PADMAVATHY MAHAL(12.919 80.089)';
  final regex = RegExp(r'\s*\((?:Lat:\s*)?[-\d.]+[,\s]+(?:Lng:\s*)?[-\d.]+\)');
  print(str1.replaceAll(regex, '').trim());
  print(str2.replaceAll(regex, '').trim());
}
