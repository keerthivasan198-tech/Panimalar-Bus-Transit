import 'package:latlong2/latlong.dart';

class CampusPoint {
  final String name;
  final String icon;
  final LatLng coords;
  CampusPoint({required this.name, required this.icon, required this.coords});
}

final List<CampusPoint> campusPoints = [
  CampusPoint(name:"Main Entrance Gate",     icon:"🚪", coords: const LatLng(13.047233247170958, 80.07553083848039)),
  CampusPoint(name:"Admin / Admission Block",icon:"🏢", coords: const LatLng(13.048850145300088, 80.07540895317958)),
  CampusPoint(name:"CSE Department",         icon:"💻", coords: const LatLng(13.049685242260539, 80.07532862941522)),
  CampusPoint(name:"AIDS (AI & Data Sci.)",  icon:"🤖", coords: const LatLng(13.049806482709092, 80.0764615955046)),
  CampusPoint(name:"ECE Department",         icon:"📡", coords: const LatLng(13.05087255939414,  80.07525881054877)),
  CampusPoint(name:"EEE Department",         icon:"⚡", coords: const LatLng(13.054592294968348, 80.07269418103328)),
  CampusPoint(name:"IT Department",          icon:"🖥️", coords: const LatLng(13.053480247199628, 80.07339790715875)),
  CampusPoint(name:"CSBS Department",        icon:"💼", coords: const LatLng(13.051718101355666, 80.07600489209125)),
  CampusPoint(name:"Mechanical Dept.",       icon:"🔧", coords: const LatLng(13.054738616658025, 80.07274023151132)),
  CampusPoint(name:"MBA Block",              icon:"📊", coords: const LatLng(13.05391294313128,  80.07533907315717)),
  CampusPoint(name:"Mess 1 (Main Mess)",     icon:"🍛", coords: const LatLng(13.050841204263154, 80.07473998885077)),
  CampusPoint(name:"Mess 2 (Hostel Mess)",   icon:"🍛", coords: const LatLng(13.053515782730686, 80.07514570981196))
];
