import Foundation

/// Formatadores de texto da interface (pt-BR).
public enum Formatters {
    /// `3h 05m` / `41m`. Arredonda para o minuto mais próximo.
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded())
        let h = minutes / 60
        let m = minutes % 60
        return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }

    /// Cronômetro `HH:MM:SS`.
    public static func stopwatch(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    /// `HH:mm` no fuso do calendário.
    public static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// Dias abreviados, segunda primeiro: `Seg`…`Dom`.
    public static let weekdaysMondayFirst = ["Seg", "Ter", "Qua", "Qui", "Sex", "Sáb", "Dom"]

    /// `Seg`, `Ter`… para a data.
    public static func weekday(_ date: Date, calendar: Calendar = .current) -> String {
        // weekday: 1 = domingo … 7 = sábado
        let weekday = calendar.component(.weekday, from: date)
        return weekdaysMondayFirst[(weekday + 5) % 7]
    }

    /// `renova 16:05` se for nas próximas 24 h, senão `renova Qui 09:00`.
    public static func reset(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "renovação desconhecida" }
        if date.timeIntervalSince(now) < 24 * 3600 {
            return "renova \(time(date, calendar: calendar))"
        }
        return "renova \(weekday(date, calendar: calendar)) \(time(date, calendar: calendar))"
    }

    /// `agora`, `há 4 min`, `há 2 h`.
    public static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "agora" }
        if minutes < 60 { return "há \(minutes) min" }
        return "há \(minutes / 60) h"
    }

    /// `5 out`, cabeçalho de datas.
    public static func shortDate(_ date: Date, calendar: Calendar = .current) -> String {
        let months = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"]
        let c = calendar.dateComponents([.day, .month], from: date)
        return "\(c.day ?? 1) \(months[(c.month ?? 1) - 1])"
    }
}
