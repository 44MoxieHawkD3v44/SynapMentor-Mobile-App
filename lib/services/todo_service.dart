import 'package:flutter/foundation.dart';

import '../api/tasks_api.dart';
import 'auth_service.dart';
import 'device_notifications.dart';
import 'notification_service.dart';

enum TaskStatus {
  todo('To Do'),
  inProgress('In Progress'),
  completed('Completed');

  const TaskStatus(this.label);
  final String label;
}

enum TaskPriority {
  low('Low', 'LOW'),
  medium('Medium', 'MED'),
  high('High', 'HIGH');

  const TaskPriority(this.label, this.short);
  final String label;
  final String short;
}

enum TaskRepeat {
  none('No repeat'),
  daily('Daily'),
  weekly('Weekly'),
  monthly('Monthly');

  const TaskRepeat(this.label);
  final String label;

  DateTime next(DateTime from) => switch (this) {
    none => from,
    daily => from.add(const Duration(days: 1)),
    weekly => from.add(const Duration(days: 7)),
    monthly => DateTime(from.year, from.month + 1, from.day, from.hour, from.minute),
  };
}

enum TaskView { all, today, upcoming, completed, overdue }

class Task {
  Task({
    required this.id,
    required this.title,
    required this.description,
    required this.due,
    required this.minutes,
    required this.priority,
    required this.category,
    required this.repeat,
    required this.tags,
    this.status = TaskStatus.todo,
    this.bookingId,
  });

  final String id;
  String title;
  String description;

  /// Local date and time the task is due.
  DateTime due;
  int minutes;
  TaskPriority priority;
  String category;
  TaskRepeat repeat;
  List<String> tags;
  TaskStatus status;

  /// Set when the task is a reminder for a booked session.
  final String? bookingId;

  /// Reminders already sent, so each goes out once.
  bool remindedSoon = false;
  bool remindedOverdue = false;

  bool get completed => status == TaskStatus.completed;

  bool get overdue => !completed && due.isBefore(DateTime.now());

  bool get dueToday {
    final now = DateTime.now();
    return due.year == now.year && due.month == now.month && due.day == now.day;
  }

  /// Whether the task falls on [day]: its due date, or for an open repeating
  /// task every day it repeats on after that. The server adds the next one
  /// only when this one is completed, so the repeats are shown from here.
  bool occursOn(DateTime day) {
    final first = DateTime(due.year, due.month, due.day);
    final d = DateTime(day.year, day.month, day.day);
    if (d == first) return true;
    if (completed || repeat == TaskRepeat.none || d.isBefore(first)) return false;
    return switch (repeat) {
      TaskRepeat.daily => true,
      TaskRepeat.weekly => d.weekday == first.weekday,
      TaskRepeat.monthly => d.day == first.day,
      TaskRepeat.none => false,
    };
  }
}

/// The user's TODO tasks, kept in sync with the tasks API, plus the reminder
/// job the backend runs.
class TodoService extends ChangeNotifier {
  static final TodoService instance = TodoService();

  /// The task categories the API accepts.
  static final categories = <String>[
    'Learning',
    'Session Prep',
    'Follow-up',
    'Project',
    'Review',
    'Practice',
    'Research',
    'Other',
  ];

  /// Suggested tags; none come from the API yet.
  static final presetTags = <String>[];

  /// Replaces the categories and suggested tags with what the API returned.
  static void setReferenceData({List<String>? categoryList, List<String>? tags}) {
    if (categoryList != null) {
      categories
        ..clear()
        ..addAll(categoryList);
    }
    if (tags != null) {
      presetTags
        ..clear()
        ..addAll(tags);
    }
  }

  /// A reminder goes out when a task is due within this window.
  static const reminderWindow = Duration(hours: 1);

  /// Shown when a task has no estimate.
  static const _defaultMinutes = 30;

  final _tasks = <String, List<Task>>{};

  /// Session reminders created here, by task id; the API doesn't keep the
  /// booking a manual task was made for.
  final _sessionTasks = <String, String>{};

  List<Task> tasks(AppUser user) => _tasks.putIfAbsent(user.email, () => []);

  /// Replaces the user's tasks with what the API returned.
  void setTasks(AppUser user, List<Task> tasks) {
    _tasks[user.email] = [...tasks];
    notifyListeners();
  }

  /// Loads the user's tasks. The list leaves out descriptions and
  /// recurrence, so each task's details are fetched too.
  Future<void> load(AppUser user) async {
    final role = user.role.name;
    final list = await TasksApi.list(role);
    final detailed = <Map<String, dynamic>>[];
    for (var i = 0; i < list.length; i += 6) {
      detailed.addAll(
        await Future.wait([
          for (final t in list.skip(i).take(6))
            TasksApi.get(role, t['id'] as String).then((d) => {...t, ...d}, onError: (Object _) => t),
        ]),
      );
    }
    setTasks(user, [
      for (final t in detailed)
        if (t['status'] != 'cancelled') _fromApi(t),
    ]);
  }

  List<Task> inView(AppUser user, TaskView view) {
    final now = DateTime.now();
    final list = tasks(user).where(
      (t) => switch (view) {
        TaskView.all => true,
        TaskView.today => !t.completed && t.occursOn(now),
        TaskView.upcoming => !t.completed && t.due.isAfter(now) && !t.dueToday,
        TaskView.completed => t.completed,
        TaskView.overdue => t.overdue,
      },
    );
    // Open tasks first, soonest due first.
    return list.toList()..sort((a, b) {
      if (a.completed != b.completed) return a.completed ? 1 : -1;
      return a.due.compareTo(b.due);
    });
  }

  bool hasSessionTask(AppUser user, String bookingId) => tasks(user).any((t) => t.bookingId == bookingId);

  Future<Task> create(
    AppUser user, {
    required String title,
    required String description,
    required DateTime due,
    required int minutes,
    required TaskPriority priority,
    required String category,
    required TaskRepeat repeat,
    required List<String> tags,
    String? bookingId,
  }) async {
    _validate(title, minutes);
    final today = DateTime.now();
    if (due.isBefore(DateTime(today.year, today.month, today.day))) {
      throw const AuthException('Pick a due date from today onwards.');
    }
    final data = await TasksApi.create(user.role.name, {
      ..._fields(
        title: title,
        description: description,
        due: due,
        minutes: minutes,
        priority: priority,
        category: category,
        tags: tags,
      ),
      'is_recurring': repeat != TaskRepeat.none,
      if (repeat != TaskRepeat.none) 'recurrence_pattern': repeat.name,
    });
    if (bookingId != null) _sessionTasks[data['id'] as String] = bookingId;
    final task = _fromApi(data);
    tasks(user)
      ..removeWhere((t) => t.id == task.id) // a quick repeat returns the same task
      ..add(task);
    notifyListeners();
    return task;
  }

  Future<void> update(
    AppUser user,
    Task task, {
    required String title,
    required String description,
    required DateTime due,
    required int minutes,
    required TaskPriority priority,
    required String category,
    required TaskRepeat repeat,
    required List<String> tags,
  }) async {
    _requireEditable(user);
    _validate(title, minutes);
    if (repeat == TaskRepeat.none && task.repeat != TaskRepeat.none) {
      throw const AuthException('A repeating task can\'t be set back to "No repeat" yet. Delete it instead.');
    }
    final role = user.role.name;
    var data = await TasksApi.update(
      role,
      task.id,
      _fields(
        title: title,
        description: description,
        due: due,
        minutes: minutes,
        priority: priority,
        category: category,
        tags: tags,
      ),
    );
    if (repeat != TaskRepeat.none && repeat != task.repeat) {
      data = await TasksApi.setRecurrence(role, task.id, repeat.name);
    }
    if (due != task.due) {
      task
        ..remindedSoon = false
        ..remindedOverdue = false;
    }
    _copy(_fromApi(data), task);
    notifyListeners();
  }

  /// Completing a recurring task schedules its next occurrence (the API
  /// creates it).
  Future<void> setStatus(AppUser user, Task task, TaskStatus status) async {
    final role = user.role.name;
    if (status == TaskStatus.completed) {
      _copy(_fromApi(await TasksApi.complete(role, task.id)), task);
      notifyListeners();
      if (task.repeat != TaskRepeat.none) await load(user);
      return;
    }
    _requireEditable(user);
    final data = await TasksApi.update(role, task.id, {
      'status': status == TaskStatus.inProgress ? 'in_progress' : 'pending',
    });
    _copy(_fromApi(data), task);
    notifyListeners();
  }

  Future<void> delete(AppUser user, Task task) async {
    await TasksApi.delete(user.role.name, task.id);
    tasks(user).remove(task);
    _sessionTasks.remove(task.id);
    notifyListeners();
  }

  /// The solver tasks API has no update endpoint yet: solvers can add,
  /// complete, repeat and delete tasks, but not edit them or reopen them.
  void _requireEditable(AppUser user) {
    if (user.role == UserRole.solver) {
      throw const AuthException('Editing tasks isn\'t available for solvers yet. You can complete or delete it.');
    }
  }

  Map<String, dynamic> _fields({
    required String title,
    required String description,
    required DateTime due,
    required int minutes,
    required TaskPriority priority,
    required String category,
    required List<String> tags,
  }) => {
    'title': title.trim(),
    'description': description.trim(),
    'priority': priority.name,
    'due_date': due.toUtc().toIso8601String(),
    'estimated_minutes': minutes,
    'tags': tags,
    if (categories.contains(category)) 'category': category,
  };

  Task _fromApi(Map<String, dynamic> t) {
    final id = t['id'] as String;
    final source = t['source_type'] as String? ?? '';
    final due =
        DateTime.tryParse(t['due_date'] as String? ?? '') ?? DateTime.tryParse(t['created_at'] as String? ?? '');
    final minutes = t['estimated_minutes'];
    return Task(
      id: id,
      title: t['title'] as String? ?? '',
      description: t['description'] as String? ?? '',
      due: (due ?? DateTime.now()).toLocal(),
      minutes: minutes is int && minutes > 0 ? minutes : _defaultMinutes,
      priority: TaskPriority.values.where((p) => p.name == t['priority']).firstOrNull ?? TaskPriority.medium,
      category: t['category'] as String? ?? 'Other',
      repeat: t['is_recurring'] == true
          ? TaskRepeat.values.where((r) => r.name == t['recurrence_pattern']).firstOrNull ?? TaskRepeat.none
          : TaskRepeat.none,
      tags: [for (final tag in t['tags'] as List? ?? const []) '$tag'],
      status: switch (t['status']) {
        'completed' => TaskStatus.completed,
        'in_progress' => TaskStatus.inProgress,
        _ => TaskStatus.todo,
      },
      bookingId: _sessionTasks[id] ?? (source.contains('booking') ? t['source_id'] as String? : null),
    );
  }

  /// Updates [task] in place, so open screens holding it see the change.
  void _copy(Task from, Task task) => task
    ..title = from.title
    ..description = from.description
    ..due = from.due
    ..minutes = from.minutes
    ..priority = from.priority
    ..category = from.category
    ..repeat = from.repeat
    ..tags = from.tags
    ..status = from.status;

  /// While the app is open: in-app notifications for tasks due within the
  /// hour and tasks that just became due, each once. When the app is in the
  /// background or closed, [DeviceNotifications] schedules them instead.
  void sendReminders(AppUser user) {
    if (!DeviceNotifications.instance.todoRemindersOn) return;
    final now = DateTime.now();
    for (final t in tasks(user).where((t) => !t.completed)) {
      if (t.overdue && !t.remindedOverdue) {
        t.remindedOverdue = t.remindedSoon = true;
        // Tasks that were overdue before the app opened don't pop up again.
        if (now.difference(t.due) > const Duration(minutes: 5)) continue;
        _remind('Due now: ${t.title}', 'This task was due ${_when(t.due)}. Mark it done or reschedule it in TODO.');
      } else if (!t.overdue && !t.remindedSoon && t.due.difference(now) <= reminderWindow) {
        t.remindedSoon = true;
        _remind('Reminder: ${t.title}', 'Due ${_when(t.due)}. Open TODO to get started.');
      }
    }
  }

  void _remind(String title, String body) =>
      NotificationService.instance.notifyLocal(title, body, type: 'todo.reminder');

  String _when(DateTime t) =>
      '${t.day}/${t.month} at ${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';

  void _validate(String title, int minutes) {
    if (title.trim().isEmpty) throw const AuthException('Give the task a title.');
    if (title.trim().length > 255) throw const AuthException('Keep the title under 255 characters.');
    if (minutes <= 0) throw const AuthException('Estimated minutes must be more than 0.');
  }
}
