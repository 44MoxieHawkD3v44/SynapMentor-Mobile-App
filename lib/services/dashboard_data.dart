import 'package:flutter/material.dart';

/// View models for the seeker dashboard tiles.

class SessionSummary {
  const SessionSummary({
    required this.title,
    required this.initials,
    required this.date,
    required this.time,
    required this.duration,
    this.photoUrl,
  });

  final String title;
  final String initials;
  final String date;
  final String time;
  final String duration;

  /// The solver's profile picture, when known.
  final String? photoUrl;
}

class CommunitySummary {
  const CommunitySummary(this.name, this.members, this.icon);

  final String name;
  final String members;
  final IconData icon;
}
