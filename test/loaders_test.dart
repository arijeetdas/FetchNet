import 'dart:math' as math;

import 'package:fetchnet/widgets/loaders.dart';
import 'package:flutter_test/flutter_test.dart';

const tau = math.pi * 2;

/// Smallest signed difference between two angles.
double angleDiff(double a, double b) {
  final d = (a - b) % tau;
  return d > math.pi ? d - tau : d;
}

double headOf(double t) {
  final a = EnergyArc.at(t);
  return a.start + a.sweep;
}

void main() {
  test('the loop has no seam: position, length and speed match at the wrap', () {
    const e = 1e-4;
    final end = EnergyArc.at(1 - e);
    final start = EnergyArc.at(e);
    expect(angleDiff(end.start, start.start).abs(), lessThan(0.01));
    expect((end.sweep - start.sweep).abs(), lessThan(0.01));
    expect(angleDiff(headOf(1 - e), headOf(e)).abs(), lessThan(0.01));

    // Angular speed just before and just after the wrap.
    const h = 1e-3;
    final tailSpeedEnd = angleDiff(EnergyArc.at(1 - h).start, EnergyArc.at(1 - 2 * h).start) / h;
    final tailSpeedStart = angleDiff(EnergyArc.at(2 * h).start, EnergyArc.at(h).start) / h;
    expect((tailSpeedEnd - tailSpeedStart).abs() / tailSpeedStart, lessThan(0.05));
    final headSpeedEnd = angleDiff(headOf(1 - h), headOf(1 - 2 * h)) / h;
    final headSpeedStart = angleDiff(headOf(2 * h), headOf(h)) / h;
    expect((headSpeedEnd - headSpeedStart).abs() / headSpeedStart, lessThan(0.05));
  });

  test('head and tail always move forward, so it never looks stuck', () {
    const steps = 2000;
    var minHeadSpeed = double.infinity;
    for (var i = 0; i < steps; i++) {
      final t0 = i / steps;
      final t1 = (i + 1) / steps;
      final tail = angleDiff(EnergyArc.at(t1).start, EnergyArc.at(t0).start);
      final head = angleDiff(headOf(t1), headOf(t0));
      expect(tail, greaterThanOrEqualTo(0), reason: 'tail moved backwards at t=$t0');
      expect(head, greaterThanOrEqualTo(0), reason: 'head moved backwards at t=$t0');
      minHeadSpeed = math.min(minHeadSpeed, head * steps);
    }
    // At least ~a third of a turn per cycle even in the slowest moment.
    expect(minHeadSpeed, greaterThan(tau / 3));
  });

  test('arc length stays visible and below a full circle', () {
    for (var i = 0; i <= 1000; i++) {
      final sweep = EnergyArc.at(i / 1000).sweep;
      expect(sweep, greaterThan(0.3));
      expect(sweep, lessThan(tau));
    }
  });
}
