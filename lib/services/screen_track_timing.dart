/// 阅读追踪与可控时钟测试共用的纯时间运算。
class ScreenTrackTiming {
  static const idleLimit = Duration(minutes: 3);
  static const maxTrackingMilliseconds = 6 * 60 * 1000;

  static bool isIdle(DateTime now, DateTime lastScrolled) =>
      now.difference(lastScrolled) > idleLimit;

  static Duration elapsed({
    required DateTime now,
    required DateTime lastTick,
    required DateTime lastScrolled,
    bool hasFocus = true,
    bool cfFrozen = false,
  }) {
    if (!hasFocus || cfFrozen || isIdle(now, lastScrolled)) {
      return Duration.zero;
    }
    final elapsed = now.difference(lastTick);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  static int submission(int pending, int alreadySubmitted) => pending.clamp(
    0,
    (maxTrackingMilliseconds - alreadySubmitted).clamp(
      0,
      maxTrackingMilliseconds,
    ),
  );
}
