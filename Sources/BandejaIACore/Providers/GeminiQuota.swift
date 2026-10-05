import Foundation

/// Regras de cota diária do Gemini: zera à meia-noite de `America/Los_Angeles`.
public enum GeminiQuota {
    public static let defaultAppPrompts = 100
    public static let cliRequests = 1000

    public static var resetCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        return calendar
    }

    /// Próxima meia-noite do Pacífico após `now`.
    public static func nextReset(after now: Date) -> Date {
        let calendar = resetCalendar
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? now
    }

    /// Chave `yyyy-MM-dd` do dia de cota que contém `date`.
    public static func quotaDay(for date: Date) -> String {
        let c = resetCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
