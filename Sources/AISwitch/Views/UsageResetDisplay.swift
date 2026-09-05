import Foundation

/// Keeps the compact meter label and its full, accessible reset time consistent.
struct UsageResetDisplay {
    let compactText: String
    let detailText: String

    init(
        window: UsageWindow?,
        isStale: Bool = false,
        now: Date = .now,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        let cachedNotice = isStale ? "Cached usage. Refresh this account to get current limits. " : ""
        guard let window else {
            compactText = "Not reported"
            detailText = cachedNotice + "Usage is not reported by the provider."
            return
        }
        guard let reset = window.resetsAt else {
            compactText = "Reset not reported"
            detailText = cachedNotice + "The provider has not reported a reset time for this limit."
            return
        }

        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        let compact = DateFormatter()
        compact.locale = locale
        compact.calendar = calendar
        compact.timeZone = timeZone
        if calendar.isDate(reset, inSameDayAs: now) {
            compact.setLocalizedDateFormatFromTemplate("jm")
            compactText = "Resets \(compact.string(from: reset))"
        } else {
            let sameYear = calendar.isDate(reset, equalTo: now, toGranularity: .year)
            compact.setLocalizedDateFormatFromTemplate(sameYear ? "MMMdjm" : "yMMMdjm")
            compactText = compact.string(from: reset)
        }

        let full = DateFormatter()
        full.locale = locale
        full.calendar = calendar
        full.timeZone = timeZone
        full.dateStyle = .full
        full.timeStyle = .long // Includes seconds and the local time zone.
        let exactTime = full.string(from: reset)
        if reset <= now {
            detailText = cachedNotice + "Reported reset: \(exactTime). This time has passed; refresh to check the new limit."
        } else {
            detailText = cachedNotice + "Resets \(exactTime)."
        }
    }
}
