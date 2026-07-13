import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:adad/main.dart';

void main() {
  group('Habit JSON backwards compatibility', () {
    test('old-format habit (no reminders, no dayColors/dayNotes) loads', () {
      // Exactly what a habit saved by the earliest app version looks like.
      const oldJson = '''
      {
        "id": "1720000000000000",
        "name": "Reading",
        "colorValue": 4294947763,
        "startDate": "2026-07-01T00:00:00.000",
        "goalDays": 30,
        "failedDates": ["2026-07-05"]
      }
      ''';

      final habit = Habit.fromJson(
        jsonDecode(oldJson) as Map<String, dynamic>,
      );

      expect(habit.id, '1720000000000000');
      expect(habit.name, 'Reading');
      expect(habit.goalDays, 30);
      expect(habit.failedDates, ['2026-07-05']);
      expect(habit.reminderTime, isNull);
      expect(habit.dayColors, isEmpty);
      expect(habit.dayNotes, isEmpty);
    });

    test('new fields round-trip through toJson/fromJson', () {
      final habit = Habit(
        id: 'x',
        name: 'Water',
        colorValue: 0xFFB3D9FF,
        startDate: DateTime(2026, 7, 1),
        failedDates: ['2026-07-03'],
        reminderHour: 9,
        reminderMinute: 30,
        dayColors: {'2026-07-02': 0xFF5F7192},
        dayNotes: {'2026-07-02': 'Felt great today'},
      );

      final restored = Habit.fromJson(
        jsonDecode(jsonEncode(habit.toJson())) as Map<String, dynamic>,
      );

      expect(restored.dayColors, {'2026-07-02': 0xFF5F7192});
      expect(restored.dayNotes, {'2026-07-02': 'Felt great today'});
      expect(restored.failedDates, ['2026-07-03']);
      expect(restored.reminderHour, 9);
      expect(restored.reminderMinute, 30);
    });

    test('habits list JSON (as stored in shared_preferences) parses', () {
      // Mixed old-format and new-format entries in one stored list.
      const storedList = '''
      [
        {"id": "a", "name": "Old", "colorValue": 1, "startDate": null,
         "goalDays": 21, "failedDates": []},
        {"id": "b", "name": "New", "colorValue": 2, "startDate": null,
         "goalDays": 14, "failedDates": [], "reminderHour": 8,
         "reminderMinute": 0, "dayColors": {"2026-07-10": 3},
         "dayNotes": {"2026-07-10": "note"}}
      ]
      ''';

      final habits = (jsonDecode(storedList) as List<dynamic>)
          .map((e) => Habit.fromJson(e as Map<String, dynamic>))
          .toList();

      expect(habits, hasLength(2));
      expect(habits[0].dayColors, isEmpty);
      expect(habits[0].dayNotes, isEmpty);
      expect(habits[1].dayColors, {'2026-07-10': 3});
      expect(habits[1].dayNotes, {'2026-07-10': 'note'});
    });
  });
}
