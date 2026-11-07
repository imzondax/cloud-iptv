enum FailoverAction { retry, switchUrl, giveUp }

/// Walks a stream's URLs, moving on after [maxFailures] consecutive failures.
class FailoverPolicy {
  FailoverPolicy(this.urls, {this.maxFailures = 3}) : assert(urls.isNotEmpty);

  final List<String> urls;
  final int maxFailures;
  int _index = 0;
  int _failures = 0;

  String get currentUrl => urls[_index];
  int get failures => _failures;

  FailoverAction onFailure() {
    if (++_failures < maxFailures) return FailoverAction.retry;
    _failures = 0;
    if (_index + 1 >= urls.length) return FailoverAction.giveUp;
    _index++;
    return FailoverAction.switchUrl;
  }

  void onHealthy() => _failures = 0;
}

/// Hysteresis over the buffered time ahead of playback, so the indicator does
/// not flicker: it turns on below [lowWater] and off again above [highWater].
class BufferGauge {
  BufferGauge({
    this.lowWater = const Duration(seconds: 1),
    this.highWater = const Duration(seconds: 3),
  });

  final Duration lowWater;
  final Duration highWater;
  bool isLow = false;

  bool update(Duration ahead) {
    if (ahead < lowWater) {
      isLow = true;
    } else if (ahead >= highWater) {
      isLow = false;
    }
    return isLow;
  }
}
