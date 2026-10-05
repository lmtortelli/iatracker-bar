import GRDB

enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "project") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique(onConflict: .ignore)
            }

            try db.create(table: "project_rule") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("project_id", .integer).notNull().indexed()
                    .references("project", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("pattern", .text).notNull()
            }

            try db.create(table: "session") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("provider", .text).notNull()
                t.column("source", .text).notNull()
                t.column("project_id", .integer).indexed()
                    .references("project", onDelete: .setNull)
                t.column("cwd", .text)
                t.column("started_at", .datetime).notNull().indexed()
                t.column("ended_at", .datetime)
                t.column("manual_project", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "counter") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("provider", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("day", .text).notNull()
                t.column("value", .integer).notNull().defaults(to: 0)
                t.uniqueKey(["provider", "kind", "day"])
            }

            try db.create(table: "limit_snapshot") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("provider", .text).notNull()
                t.column("window", .text).notNull()
                t.column("used_pct", .double).notNull()
                t.column("reset_at", .datetime)
                t.column("source", .text).notNull()
                t.column("fetched_at", .datetime).notNull()
            }
            try db.create(index: "limit_snapshot_latest", on: "limit_snapshot", columns: ["provider", "window", "fetched_at"])
        }

        // Fase 3: posição lida em cada arquivo de log e a sessão aberta que ele alimenta.
        migrator.registerMigration("v2_log_cursor") { db in
            try db.create(table: "log_cursor") { t in
                t.column("path", .text).primaryKey()
                t.column("offset", .integer).notNull().defaults(to: 0)
                t.column("session_id", .integer).references("session", onDelete: .setNull)
                t.column("last_event_at", .datetime)
            }
        }

        return migrator
    }
}
