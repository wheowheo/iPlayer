import Foundation
import SQLite3

// MARK: - 의류 모델

enum ClothingType: String, CaseIterable {
    case top = "상의"
    case bottom = "하의"
    case fullBody = "원피스"
    case hat = "모자"
    case accessory = "액세서리"
}

struct ClothingItem: Identifiable {
    let id: Int64
    var name: String
    var type: ClothingType
    var colorHex: String      // "#FF0000"
    var opacity: Double       // 0.0~1.0
    var pattern: String       // "solid", "stripe", "check"
    var modelFile: String     // 3D 모델 파일명 ("tshirt.obj")
    var notes: String
    var createdAt: Date
    var isActive: Bool

    var color: (r: CGFloat, g: CGFloat, b: CGFloat) {
        let hex = colorHex.dropFirst()
        let val = UInt64(hex, radix: 16) ?? 0
        return (r: CGFloat((val >> 16) & 0xFF) / 255,
                g: CGFloat((val >> 8) & 0xFF) / 255,
                b: CGFloat(val & 0xFF) / 255)
    }
}

// MARK: - SQLite 데이터베이스

final class ClothingDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    nonisolated(unsafe) static let shared = ClothingDatabase()

    private init() {
        openDatabase()
        createTable()
    }

    deinit {
        sqlite3_close(db)
    }

    private func openDatabase() {
        // AppDatabase와 동일한 DB 파일 사용
        let dbDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("iPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let dbPath = dbDir.appendingPathComponent("iPlayer.db").path

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            log("[ClothingDB] 데이터베이스 열기 실패: \(dbPath)")
            return
        }
    }

    private func createTable() {
        // AppDatabase.shared가 clothing 테이블 생성 + 시딩 담당
        // ClothingDatabase는 clothing 테이블에 대한 CRUD만 수행
        _ = AppDatabase.shared  // 테이블 보장
    }

    // MARK: - CRUD

    @discardableResult
    func insert(name: String, type: ClothingType, colorHex: String = "#3366FF",
                opacity: Double = 0.7, pattern: String = "solid",
                modelFile: String = "", notes: String = "", createdAt: Double? = nil) -> Int64 {
        let sql = "INSERT INTO clothing (name, type, color_hex, opacity, pattern, model_file, notes, created_at, is_active) VALUES (?,?,?,?,?,?,?,?,1)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (type.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (colorHex as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 4, opacity)
        sqlite3_bind_text(stmt, 5, (pattern as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (modelFile as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 7, (notes as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 8, createdAt ?? Date().timeIntervalSince1970)

        if sqlite3_step(stmt) == SQLITE_DONE {
            return sqlite3_last_insert_rowid(db)
        }
        return -1
    }

    func fetchAll() -> [ClothingItem] {
        let sql = "SELECT id, name, type, color_hex, opacity, pattern, model_file, notes, created_at, is_active FROM clothing ORDER BY type, name"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var items: [ClothingItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(rowToItem(stmt!))
        }
        return items
    }

    func fetchByType(_ type: ClothingType) -> [ClothingItem] {
        let sql = "SELECT id, name, type, color_hex, opacity, pattern, model_file, notes, created_at, is_active FROM clothing WHERE type = ? ORDER BY name"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (type.rawValue as NSString).utf8String, -1, nil)

        var items: [ClothingItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(rowToItem(stmt!))
        }
        return items
    }

    func fetchActive() -> [ClothingItem] {
        let sql = "SELECT id, name, type, color_hex, opacity, pattern, model_file, notes, created_at, is_active FROM clothing WHERE is_active = 1 ORDER BY type"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var items: [ClothingItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(rowToItem(stmt!))
        }
        return items
    }

    func update(_ item: ClothingItem) {
        let sql = "UPDATE clothing SET name=?, type=?, color_hex=?, opacity=?, pattern=?, model_file=?, notes=?, is_active=? WHERE id=?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (item.name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (item.type.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (item.colorHex as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 4, item.opacity)
        sqlite3_bind_text(stmt, 5, (item.pattern as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (item.modelFile as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 7, (item.notes as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 8, item.isActive ? 1 : 0)
        sqlite3_bind_int64(stmt, 9, item.id)

        sqlite3_step(stmt)
    }

    func delete(id: Int64) {
        exec("DELETE FROM clothing WHERE id = \(id)")
    }

    func toggleActive(id: Int64) {
        exec("UPDATE clothing SET is_active = CASE WHEN is_active = 1 THEN 0 ELSE 1 END WHERE id = \(id)")
    }

    func stats() -> (total: Int, active: Int, byType: [(ClothingType, Int)]) {
        var total = 0, active = 0
        var byType: [(ClothingType, Int)] = []

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM clothing", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { total = Int(sqlite3_column_int(stmt, 0)) }
            sqlite3_finalize(stmt)
        }
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM clothing WHERE is_active = 1", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { active = Int(sqlite3_column_int(stmt, 0)) }
            sqlite3_finalize(stmt)
        }
        for type in ClothingType.allCases {
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM clothing WHERE type = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (type.rawValue as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let count = Int(sqlite3_column_int(stmt, 0))
                    if count > 0 { byType.append((type, count)) }
                }
                sqlite3_finalize(stmt)
            }
        }
        return (total, active, byType)
    }

    // MARK: - Private

    private func rowToItem(_ stmt: OpaquePointer) -> ClothingItem {
        let typeStr = String(cString: sqlite3_column_text(stmt, 2))
        return ClothingItem(
            id: sqlite3_column_int64(stmt, 0),
            name: String(cString: sqlite3_column_text(stmt, 1)),
            type: ClothingType(rawValue: typeStr) ?? .top,
            colorHex: String(cString: sqlite3_column_text(stmt, 3)),
            opacity: sqlite3_column_double(stmt, 4),
            pattern: String(cString: sqlite3_column_text(stmt, 5)),
            modelFile: sqlite3_column_text(stmt, 6) != nil ? String(cString: sqlite3_column_text(stmt, 6)) : "",
            notes: sqlite3_column_text(stmt, 7) != nil ? String(cString: sqlite3_column_text(stmt, 7)) : "",
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
            isActive: sqlite3_column_int(stmt, 9) == 1
        )
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}
