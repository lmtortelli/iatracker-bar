import Foundation

// Mini-harness: as Command Line Tools não incluem XCTest.
// Rode com `swift run iatracker-tests`. Sai com código 1 se algum teste falhar.

TestRunner.run([
    ("Formatters", FormattersTests.all),
    ("ReportAggregator", ReportAggregatorTests.all),
    ("GeminiQuota", GeminiQuotaTests.all),
    ("AppDatabase", DatabaseTests.all),
    ("ActivityClassifier", ActivityClassifierTests.all),
    ("SessionTracker", SessionTrackerTests.all),
    ("ProjectResolver", ProjectResolverTests.all),
    ("ClaudeCodeLog", ClaudeCodeLogTests.all),
    ("GeminiCLILog", GeminiCLILogTests.all),
    ("ClaudeLimits", ClaudeLimitsTests.all),
    ("ClaudeEstimator", ClaudeEstimatorTests.all),
    ("GeminiLimits", GeminiLimitsTests.all),
    ("LimitAlerts", LimitAlertsTests.all),
])
