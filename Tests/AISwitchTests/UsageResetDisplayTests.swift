import Foundation
import Testing
@testable import AISwitch

private let resetInstant = ISO8601DateFormatter().date(from: "2026-09-05T14:01:55Z")!
private let beforeReset = ISO8601DateFormatter().date(from: "2026-09-05T09:21:02Z")!
private let jakarta = TimeZone(identifier: "Asia/Jakarta")!
private let britishEnglish = Locale(identifier: "en_GB")

@Test("An exhausted limit shows its local clock time and full precision")
func exhaustedLimitShowsExactReset() {
    let display = UsageResetDisplay(
        window: UsageWindow(usedPercent: 100, resetsAt: resetInstant),
        now: beforeReset, locale: britishEnglish, timeZone: jakarta
    )
    #expect(display.compactText == "Resets 21:01")
    #expect(display.detailText.contains("21:01:55"))
    #expect(display.detailText.contains("5 September 2026"))
    #expect(display.detailText.contains("GMT+7"))
}

@Test("Reset clocks respect twelve-hour locale formatting")
func resetUsesLocaleClock() {
    let display = UsageResetDisplay(
        window: UsageWindow(usedPercent: 100, resetsAt: resetInstant),
        now: beforeReset, locale: Locale(identifier: "en_US"), timeZone: jakarta
    )
    #expect(display.compactText.contains("9:01"))
    #expect(display.compactText.contains("PM"))
    #expect(display.detailText.contains("9:01:55"))
}

@Test("Weekly reset includes a date as well as a clock time")
func weeklyResetIncludesDate() {
    let reset = ISO8601DateFormatter().date(from: "2026-09-12T09:01:55Z")!
    let display = UsageResetDisplay(
        window: UsageWindow(usedPercent: 16, resetsAt: reset),
        now: beforeReset, locale: britishEnglish, timeZone: jakarta
    )
    #expect(display.compactText.contains("12 Sep"))
    #expect(display.compactText.contains("16:01"))
    #expect(display.detailText.contains("16:01:55"))
}

@Test("Today is determined in the display time zone, not UTC")
func resetUsesLocalDayBoundary() {
    let reset = ISO8601DateFormatter().date(from: "2026-09-05T18:01:55Z")!
    let window = UsageWindow(usedPercent: 100, resetsAt: reset)
    let local = UsageResetDisplay(window: window, now: beforeReset, locale: britishEnglish, timeZone: jakarta)
    let utc = UsageResetDisplay(window: window, now: beforeReset, locale: britishEnglish, timeZone: TimeZone(secondsFromGMT: 0)!)
    #expect(local.compactText.contains("6 Sep"))
    #expect(local.compactText.contains("01:01"))
    #expect(utc.compactText == "Resets 18:01")
}

@Test("A reset in another year is not ambiguous")
func resetIncludesDifferentYear() {
    let reset = ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z")!
    let display = UsageResetDisplay(
        window: UsageWindow(usedPercent: 100, resetsAt: reset),
        now: beforeReset, locale: britishEnglish, timeZone: jakarta
    )
    #expect(display.compactText.contains("2027"))
    #expect(display.compactText.contains("07:00"))
}

@Test("Missing reset timestamps are explicit and never invented")
func missingResetIsExplicit() {
    let missingReset = UsageResetDisplay(window: UsageWindow(usedPercent: 100, resetsAt: nil))
    #expect(missingReset.compactText == "Reset not reported")
    #expect(missingReset.detailText.contains("has not reported a reset time"))
    let missingWindow = UsageResetDisplay(window: nil)
    #expect(missingWindow.compactText == "Not reported")
    #expect(missingWindow.detailText == "Usage is not reported by the provider.")
}

@Test("Cached and elapsed resets retain their exact reported timestamps")
func cachedAndElapsedResetsRetainPrecision() {
    let window = UsageWindow(usedPercent: 100, resetsAt: resetInstant)
    let cached = UsageResetDisplay(
        window: window, isStale: true, now: beforeReset,
        locale: britishEnglish, timeZone: jakarta
    )
    #expect(cached.detailText.hasPrefix("Cached usage."))
    #expect(cached.detailText.contains("21:01:55"))
    let elapsed = UsageResetDisplay(
        window: window, now: resetInstant.addingTimeInterval(1),
        locale: britishEnglish, timeZone: jakarta
    )
    #expect(elapsed.compactText == "Resets 21:01")
    #expect(elapsed.detailText.contains("21:01:55"))
    #expect(elapsed.detailText.contains("This time has passed"))
}
