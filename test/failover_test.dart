import 'package:cloud_iptv/player/failover.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('switches after exactly 3 consecutive failures, then gives up', () {
    final p = FailoverPolicy(['a', 'b']);
    expect(p.onFailure(), FailoverAction.retry);
    expect(p.onFailure(), FailoverAction.retry);
    expect(p.currentUrl, 'a');
    expect(p.onFailure(), FailoverAction.switchUrl);
    expect(p.currentUrl, 'b');
    expect(p.onFailure(), FailoverAction.retry);
    expect(p.onFailure(), FailoverAction.retry);
    expect(p.onFailure(), FailoverAction.giveUp);
  });

  test('healthy playback resets the count', () {
    final p = FailoverPolicy(['a', 'b']);
    p.onFailure();
    p.onFailure();
    p.onHealthy();
    expect(p.onFailure(), FailoverAction.retry);
    expect(p.currentUrl, 'a');
  });

  test('buffer gauge has hysteresis between the water marks', () {
    final g = BufferGauge();
    expect(g.update(const Duration(seconds: 2)), isFalse);
    expect(g.update(const Duration(milliseconds: 500)), isTrue);
    expect(g.update(const Duration(seconds: 2)), isTrue);
    expect(g.update(const Duration(seconds: 3)), isFalse);
  });
}
