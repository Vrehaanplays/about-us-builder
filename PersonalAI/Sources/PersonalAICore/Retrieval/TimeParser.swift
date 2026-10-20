import Foundation

public struct TimeConstraint: Sendable, Equatable {
    public var from: Double
    public var to: Double
    /// Hard: an explicit date ("in March 2024", "yesterday") filters. Soft: fuzzy ("a few months ago") only re-weights.
    public var hard: Bool
    public var label: String
}

/// Natural-language date expressions → time ranges. Deliberately rule-based: deterministic, instant, offline.
public struct TimeParser: Sendable {
    public var calendar: Calendar
    public init(calendar: Calendar = .current) { self.calendar = calendar }

    static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    static let monthsShort = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    static let numberWords: [String: Int] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "couple": 2, "few": 3, "several": 4]

    public func parse(_ text: String, now: Date) -> TimeConstraint? {
        let q = text.lowercased()
        let cal = calendar
        func startOfDay(_ d: Date) -> Date { cal.startOfDay(for: d) }
        func add(_ c: Calendar.Component, _ n: Int, to d: Date) -> Date { cal.date(byAdding: c, value: n, to: d)! }
        // a range that starts after "now" cannot be when something was *said*; it is when something is *about*, so it only boosts, never filters
        func range(_ a: Date, _ b: Date, hard: Bool, _ label: String) -> TimeConstraint { TimeConstraint(from: a.timeIntervalSince1970, to: b.timeIntervalSince1970, hard: hard && a <= now, label: label) }
        let today = startOfDay(now)

        if q.contains("yesterday") { return range(add(.day, -1, to: today), today, hard: true, "yesterday") }
        if q.range(of: #"\btoday\b"#, options: .regularExpression) != nil { return range(today, add(.day, 1, to: today), hard: true, "today") }
        if q.contains("last week") { let w = cal.dateInterval(of: .weekOfYear, for: add(.weekOfYear, -1, to: now))!; return range(w.start, w.end, hard: true, "last week") }
        if q.contains("this week") { let w = cal.dateInterval(of: .weekOfYear, for: now)!; return range(w.start, w.end, hard: true, "this week") }
        if q.contains("last month") { let m = cal.dateInterval(of: .month, for: add(.month, -1, to: now))!; return range(m.start, m.end, hard: true, "last month") }
        if q.contains("this month") { let m = cal.dateInterval(of: .month, for: now)!; return range(m.start, m.end, hard: true, "this month") }
        if q.contains("last year") { let y = cal.dateInterval(of: .year, for: add(.year, -1, to: now))!; return range(y.start, y.end, hard: true, "last year") }
        if q.contains("this year") { let y = cal.dateInterval(of: .year, for: now)!; return range(y.start, y.end, hard: true, "this year") }

        // "N units ago" / "a few months ago"
        if let m = q.range(of: #"\b(\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|couple of|few|several)\s+(day|week|month|year)s?\s+(?:ago|back)\b"#, options: .regularExpression) {
            let parts = q[m].split(separator: " ").map(String.init)
            var nTok = parts[0]
            if nTok == "couple" || nTok == "a" && parts.count > 1 && parts[1] == "couple" { nTok = "couple" }
            let n = Int(nTok) ?? Self.numberWords[nTok] ?? 1
            let unitStr = parts.first { $0.hasPrefix("day") || $0.hasPrefix("week") || $0.hasPrefix("month") || $0.hasPrefix("year") } ?? "week"
            let comp: Calendar.Component = unitStr.hasPrefix("day") ? .day : unitStr.hasPrefix("week") ? .weekOfYear : unitStr.hasPrefix("month") ? .month : .year
            let fuzzy = ["few", "couple", "several"].contains(nTok)
            let center = add(comp, -n, to: now)
            let spread = comp == .day ? 2 : comp == .weekOfYear ? 1 : comp == .month ? 1 : 1
            let lo = add(comp, -(spread + (fuzzy ? n : 0)), to: center), hi = add(comp, spread + (fuzzy ? 1 : 0), to: center)
            return range(startOfDay(lo), min(hi, now), hard: false, "\(nTok) \(unitStr)s ago")
        }
        if q.contains("recently") || q.contains("lately") { return range(add(.day, -30, to: today), add(.day, 1, to: today), hard: false, "recently") }
        if q.contains("a while ago") || q.contains("a while back") || q.contains("long ago") { return range(Date(timeIntervalSince1970: 0), add(.month, -2, to: now), hard: false, "a while ago") }

        // seasons
        if let m = q.range(of: #"\blast (spring|summer|autumn|fall|winter)\b"#, options: .regularExpression) {
            let s = String(q[m]).split(separator: " ")[1]
            let (startMonth, len): (Int, Int) = s == "spring" ? (3, 3) : s == "summer" ? (6, 3) : (s == "autumn" || s == "fall") ? (9, 3) : (12, 3)
            var y = cal.component(.year, from: now)
            func seasonStart(_ y: Int) -> Date { cal.date(from: DateComponents(year: y, month: startMonth, day: 1))! }
            if seasonStart(y) > now { y -= 1 }
            if add(.month, len, to: seasonStart(y)) > now { y -= 1 }   // season still in progress: "last" means the previous one
            let a = seasonStart(y)
            return range(a, add(.month, len, to: a), hard: true, "last \(s)")
        }

        // "in March", "in March 2024", "march 2024"
        let monthAlt = (Self.months + ["sept"]).joined(separator: "|")
        if let m = q.range(of: #"\b(?:in |during |back in |around )?(\#(monthAlt))\b(?:\s+(?:of\s+)?(\d{4}))?"#, options: .regularExpression) {
            let frag = String(q[m])
            if let name = (Self.months + ["sept"]).first(where: { frag.contains($0) }), name != "may" || frag.contains("in may") || frag.contains("may 20") || frag.contains("during may") || frag.contains("around may") || frag.contains("back in may") {
                let mi = (name == "sept" ? 8 : Self.months.firstIndex(of: name)!) + 1
                var year = cal.component(.year, from: now)
                if let ym = frag.range(of: #"\d{4}"#, options: .regularExpression) { year = Int(frag[ym])! }
                else if cal.date(from: DateComponents(year: year, month: mi, day: 1))! > now { year -= 1 }   // most recent past occurrence
                let a = cal.date(from: DateComponents(year: year, month: mi, day: 1))!
                return range(a, add(.month, 1, to: a), hard: true, "\(name.capitalized) \(year)")
            }
        }
        if let m = q.range(of: #"\b(?:in |during |back in |from )?((?:19|20)\d{2})\b"#, options: .regularExpression) {
            let ym = q[m].range(of: #"(?:19|20)\d{2}"#, options: .regularExpression)!
            let y = Int(q[m][ym])!
            let a = cal.date(from: DateComponents(year: y, month: 1, day: 1))!
            return range(a, add(.year, 1, to: a), hard: true, "\(y)")
        }
        return nil
    }
}
