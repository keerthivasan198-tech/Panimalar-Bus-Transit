import 'package:flutter_test/flutter_test.dart';

// Standalone class reflecting the exact logic in DriverDashboard
class GpsAlarmWatchdogEngine {
  Map<String, dynamic> dynamicShiftSchedule = {};
  bool gpsAlarmGlobalEnabled = true;
  bool isTracking = false;
  bool isParked = false;
  bool breakdownActive = false;
  DateTime? gpsAlarmSnoozedUntil;
  bool isGpsAlarmRinging = false;
  String activeAlarmShiftName = "";

  int? parseTimeToMinutes(dynamic timeInput) {
    if (timeInput == null) return null;
    final str = timeInput.toString().trim().toUpperCase();
    if (str.isEmpty) return null;

    try {
      final isPm = str.contains('PM');
      final isAm = str.contains('AM');
      final cleanStr = str.replaceAll('AM', '').replaceAll('PM', '').trim();
      final parts = cleanStr.split(':');
      if (parts.length >= 2) {
        int hour = int.parse(parts[0].trim());
        int minute = int.parse(parts[1].trim());
        if (isPm && hour < 12) hour += 12;
        if (isAm && hour == 12) hour = 0;
        return hour * 60 + minute;
      }
    } catch (_) {}
    return null;
  }

  String? getCurrentActiveShift(DateTime now) {
    final weekday = now.weekday; // 1 = Mon, 7 = Sun

    final activeDays = dynamicShiftSchedule['active_days'];
    if (activeDays != null) {
      if (activeDays is List && !activeDays.contains(weekday) && !activeDays.contains(weekday.toString())) {
        return null;
      } else if (activeDays is String && !activeDays.contains(weekday.toString())) {
        return null;
      }
    } else {
      if (weekday == DateTime.sunday) {
        return null;
      }
    }

    final currentMinutes = now.hour * 60 + now.minute;

    // Morning shift default: 06:00 (360) to 07:45 (465)
    final morningStart = parseTimeToMinutes(dynamicShiftSchedule['morning_start']) ?? (6 * 60);
    final morningEnd = parseTimeToMinutes(dynamicShiftSchedule['morning_end']) ?? (7 * 60 + 45);

    if (currentMinutes >= morningStart && currentMinutes <= morningEnd) {
      return "Morning Shift";
    }

    // Evening shift default: 15:00 (900) to 17:45 (1065)
    final eveningStart = parseTimeToMinutes(dynamicShiftSchedule['evening_start']) ?? (15 * 60);
    final eveningEnd = parseTimeToMinutes(dynamicShiftSchedule['evening_end']) ?? (17 * 60 + 45);

    if (currentMinutes >= eveningStart && currentMinutes <= eveningEnd) {
      return "Evening Shift";
    }

    return null;
  }

  void evaluateWatchdog(DateTime simulatedNow) {
    if (!gpsAlarmGlobalEnabled || isTracking || isParked || breakdownActive) {
      if (isGpsAlarmRinging) {
        dismissGpsAlarm();
      }
      return;
    }

    if (gpsAlarmSnoozedUntil != null && simulatedNow.isBefore(gpsAlarmSnoozedUntil!)) {
      if (isGpsAlarmRinging) {
        dismissGpsAlarm();
      }
      return;
    }

    final activeShift = getCurrentActiveShift(simulatedNow);
    if (activeShift != null) {
      activeAlarmShiftName = activeShift;
      isGpsAlarmRinging = true;
    } else {
      if (isGpsAlarmRinging) {
        dismissGpsAlarm();
      }
    }
  }

  void dismissGpsAlarm() {
    isGpsAlarmRinging = false;
  }

  void snooze(DateTime now) {
    dismissGpsAlarm();
    gpsAlarmSnoozedUntil = now.add(const Duration(minutes: 5));
  }

  void startTracking() {
    dismissGpsAlarm();
    isTracking = true;
    isParked = false;
  }

  void parkBus() {
    dismissGpsAlarm();
    isParked = true;
    isTracking = false;
  }
}

void main() {
  group('GPS Alarm Watchdog Engine Unit Tests', () {
    late GpsAlarmWatchdogEngine engine;

    setUp(() {
      engine = GpsAlarmWatchdogEngine();
    });

    test('Parses 24h and 12h time formats correctly', () {
      expect(engine.parseTimeToMinutes("06:00"), 360);
      expect(engine.parseTimeToMinutes("08:45"), 525);
      expect(engine.parseTimeToMinutes("3:00 PM"), 900);
      expect(engine.parseTimeToMinutes("05:30 PM"), 1050);
      expect(engine.parseTimeToMinutes("12:00 AM"), 0);
      expect(engine.parseTimeToMinutes("12:30 PM"), 750);
      expect(engine.parseTimeToMinutes(null), isNull);
    });

    test('Identifies default morning shift (06:00 to 07:45) on Monday', () {
      // 2026-10-05 is a Monday
      final morningTime = DateTime(2026, 10, 5, 7, 15);
      expect(engine.getCurrentActiveShift(morningTime), "Morning Shift");

      // 08:00 AM is now outside the morning shift
      final afterMorning = DateTime(2026, 10, 5, 8, 0);
      expect(engine.getCurrentActiveShift(afterMorning), isNull);
    });

    test('Identifies default evening shift (15:00 to 17:45) on Friday', () {
      // 2026-10-09 is a Friday
      final eveningTime = DateTime(2026, 10, 9, 16, 30);
      expect(engine.getCurrentActiveShift(eveningTime), "Evening Shift");
    });

    test('Returns null outside travel shifts (e.g. 11:00 AM midday)', () {
      final midDay = DateTime(2026, 10, 5, 11, 0);
      expect(engine.getCurrentActiveShift(midDay), isNull);
    });

    test('Skips Sunday by default', () {
      // 2026-10-11 is a Sunday
      final sundayMorning = DateTime(2026, 10, 11, 7, 0);
      expect(engine.getCurrentActiveShift(sundayMorning), isNull);
    });

    test('Supports dynamic custom route shift timings from Firebase', () {
      // Custom schedule: Morning 05:30 - 07:30, Evening 16:30 - 19:00
      engine.dynamicShiftSchedule = {
        'morning_start': '05:30',
        'morning_end': '07:30',
        'evening_start': '16:30',
        'evening_end': '19:00',
      };

      final customMorning = DateTime(2026, 10, 5, 5, 45);
      expect(engine.getCurrentActiveShift(customMorning), "Morning Shift");

      final oldDefaultTime = DateTime(2026, 10, 5, 8, 0); // 8:00 is after 7:30
      expect(engine.getCurrentActiveShift(oldDefaultTime), isNull);
    });

    test('Triggers alarm when in shift and GPS tracking is OFF', () {
      final morningTime = DateTime(2026, 10, 5, 7, 0);
      engine.evaluateWatchdog(morningTime);

      expect(engine.isGpsAlarmRinging, isTrue);
      expect(engine.activeAlarmShiftName, "Morning Shift");
    });

    test('Suppresses alarm when driver starts tracking', () {
      final morningTime = DateTime(2026, 10, 5, 7, 0);
      engine.evaluateWatchdog(morningTime);
      expect(engine.isGpsAlarmRinging, isTrue);

      // Driver taps Start Tracking
      engine.startTracking();
      expect(engine.isGpsAlarmRinging, isFalse);

      // Next watchdog evaluation
      engine.evaluateWatchdog(morningTime);
      expect(engine.isGpsAlarmRinging, isFalse);
    });

    test('Suppresses alarm when bus is parked in campus', () {
      final morningTime = DateTime(2026, 10, 5, 7, 0);
      engine.evaluateWatchdog(morningTime);
      expect(engine.isGpsAlarmRinging, isTrue);

      // Driver marks parked in campus
      engine.parkBus();
      expect(engine.isGpsAlarmRinging, isFalse);

      engine.evaluateWatchdog(morningTime);
      expect(engine.isGpsAlarmRinging, isFalse);
    });

    test('Snooze suppresses alarm for 5 minutes', () {
      final morningTime = DateTime(2026, 10, 5, 7, 0);
      engine.evaluateWatchdog(morningTime);
      expect(engine.isGpsAlarmRinging, isTrue);

      // Driver snoozes
      engine.snooze(morningTime);
      expect(engine.isGpsAlarmRinging, isFalse);

      // After 3 minutes, still snoozed
      engine.evaluateWatchdog(morningTime.add(const Duration(minutes: 3)));
      expect(engine.isGpsAlarmRinging, isFalse);

      // After 6 minutes, snooze expired -> rings again
      engine.evaluateWatchdog(morningTime.add(const Duration(minutes: 6)));
      expect(engine.isGpsAlarmRinging, isTrue);
    });
  });
}
