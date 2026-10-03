import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/screen_track_timing.dart';

void main() {
  final start = DateTime.utc(2026);
  Duration sample(int seconds, {bool focus = true, bool frozen = false}) =>
      ScreenTrackTiming.elapsed(
        now: start.add(Duration(seconds: seconds)),
        lastTick: start.add(Duration(seconds: seconds - 1)),
        lastScrolled: start,
        hasFocus: focus,
        cfFrozen: frozen,
      );

  test('three minute boundary retains normal final second', () {
    expect(sample(179), const Duration(seconds: 1));
    expect(sample(180), const Duration(seconds: 1));
    expect(sample(181), Duration.zero);
  });

  test('focus and CF freeze exclude elapsed time', () {
    expect(sample(10, focus: false), Duration.zero);
    expect(sample(10, frozen: true), Duration.zero);
    expect(sample(11), const Duration(seconds: 1));
  });

  test('long idle resume resets baseline before next sample', () {
    var lastTick = start;
    var lastScrolled = start;
    final resumed = start.add(const Duration(hours: 2));
    expect(
      ScreenTrackTiming.elapsed(
        now: resumed,
        lastTick: lastTick,
        lastScrolled: lastScrolled,
      ),
      Duration.zero,
    );
    // Same idle-resume rule used by ScreenTrack.scrolled, including when no
    // periodic timer fired while paused.
    if (ScreenTrackTiming.isIdle(resumed, lastScrolled)) lastTick = resumed;
    lastScrolled = resumed;
    expect(
      ScreenTrackTiming.elapsed(
        now: resumed.add(const Duration(seconds: 1)),
        lastTick: lastTick,
        lastScrolled: lastScrolled,
      ),
      const Duration(seconds: 1),
    );
  });

  test('cap submits only remaining allowance, never negative', () {
    expect(ScreenTrackTiming.submission(2000, 359000), 1000);
    expect(ScreenTrackTiming.submission(2000, 360000), 0);
    expect(ScreenTrackTiming.submission(2000, 400000), 0);
    expect(ScreenTrackTiming.submission(-1, 0), 0);
    expect(ScreenTrackTiming.submission(9999999, 0), 360000);
  });

  test('backwards clock cannot subtract reading time', () {
    expect(
      ScreenTrackTiming.elapsed(
        now: start,
        lastTick: start.add(const Duration(seconds: 1)),
        lastScrolled: start,
      ),
      Duration.zero,
    );
  });
}
