import base64

with open(r'c:\Users\Siva\Downloads\panimalarbus\panimalar-bus\assets\images\bus_breakdown_icon.png', 'rb') as f:
    b64_breakdown = base64.b64encode(f.read()).decode('utf-8')

with open(r'c:\Users\Siva\Downloads\panimalarbus\panimalar-bus\assets\images\bus_ready_icon.png', 'rb') as f:
    b64_ready = base64.b64encode(f.read()).decode('utf-8')

with open(r'c:\Users\Siva\Downloads\panimalarbus\panimalar-bus\assets\images\bus_park_sign.png', 'rb') as f:
    b64_park = base64.b64encode(f.read()).decode('utf-8')

with open(r'c:\Users\Siva\Downloads\panimalarbus\panimalar-bus\assets\images\yellow_bus.png', 'rb') as f:
    b64_yellow_bus = base64.b64encode(f.read()).decode('utf-8')

with open(r'c:\Users\Siva\Downloads\panimalarbus\panimalar-bus\assets\images\panimalar_bus1.png', 'rb') as f:
    b64_panimalar_bus1 = base64.b64encode(f.read()).decode('utf-8')

with open(r'c:\Users\Siva\Downloads\panimalarbus\panimalar-bus\lib\screens\driver\bus_card_icons.dart', 'w') as f:
    f.write(f'''import 'dart:convert';
import 'dart:typed_data';

class BusCardIcons {{
  static const String breakdownB64 = "{b64_breakdown}";
  static const String readyB64 = "{b64_ready}";
  static const String parkB64 = "{b64_park}";
  static const String yellowBusB64 = "{b64_yellow_bus}";
  static const String panimalarBus1B64 = "{b64_panimalar_bus1}";

  static final Uint8List breakdownBytes = base64Decode(breakdownB64);
  static final Uint8List readyBytes = base64Decode(readyB64);
  static final Uint8List parkBytes = base64Decode(parkB64);
  static final Uint8List yellowBusBytes = base64Decode(yellowBusB64);
  static final Uint8List panimalarBus1Bytes = base64Decode(panimalarBus1B64);
}}
''')

print("Updated bus_card_icons.dart with yellow_bus and panimalar_bus1!")
