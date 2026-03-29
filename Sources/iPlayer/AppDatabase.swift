import Foundation
import SQLite3

/// iPlayer 통합 SQLite 데이터베이스
/// - 재생 이력, 사용자 설정, AI 모델 설정, 얼굴 합성 캘리브레이션, 의류
final class AppDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    nonisolated(unsafe) static let shared = AppDatabase()

    private init() {
        openDatabase()
        createTables()
        seedDefaults()
    }

    deinit { sqlite3_close(db) }

    private func openDatabase() {
        let dbDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("iPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let dbPath = dbDir.appendingPathComponent("iPlayer.db").path

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            log("[DB] 열기 실패: \(dbPath)")
            return
        }
        exec("PRAGMA journal_mode=WAL")  // 읽기/쓰기 동시성
        log("[DB] 열림: \(dbPath)")
    }

    // MARK: - 테이블 생성

    private func createTables() {
        // 1. 재생 이력
        exec("""
        CREATE TABLE IF NOT EXISTS play_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_path TEXT NOT NULL UNIQUE,
            file_name TEXT NOT NULL,
            last_position REAL DEFAULT 0,
            duration REAL DEFAULT 0,
            play_count INTEGER DEFAULT 1,
            last_played REAL NOT NULL,
            video_codec TEXT DEFAULT '',
            audio_codec TEXT DEFAULT '',
            width INTEGER DEFAULT 0,
            height INTEGER DEFAULT 0
        )
        """)

        // 2. 사용자 설정
        exec("""
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            type TEXT DEFAULT 'string'
        )
        """)

        // 3. AI 모델 설정
        exec("""
        CREATE TABLE IF NOT EXISTS ai_presets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            mode TEXT NOT NULL,
            name TEXT NOT NULL,
            confidence_threshold REAL DEFAULT 0.5,
            frame_skip_interval INTEGER DEFAULT 3,
            is_default INTEGER DEFAULT 0
        )
        """)

        // 4. 얼굴 합성 캘리브레이션
        exec("""
        CREATE TABLE IF NOT EXISTS face_calibration (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            uv_left_eye_x REAL, uv_left_eye_y REAL,
            uv_right_eye_x REAL, uv_right_eye_y REAL,
            uv_nose_x REAL, uv_nose_y REAL,
            uv_mouth_x REAL, uv_mouth_y REAL,
            bbox_expand_top REAL DEFAULT 0.35,
            bbox_expand_bottom REAL DEFAULT 0.15,
            bbox_expand_side REAL DEFAULT 0.15,
            pose_pitch_base REAL DEFAULT 0.65,
            pose_pitch_sensitivity REAL DEFAULT 1.5,
            pose_yaw_sensitivity REAL DEFAULT 3.0,
            is_active INTEGER DEFAULT 1
        )
        """)

        // 5. 의류 (기존 ClothingDatabase에서 이관)
        exec("""
        CREATE TABLE IF NOT EXISTS clothing (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            type TEXT NOT NULL DEFAULT '상의',
            color_hex TEXT NOT NULL DEFAULT '#3366FF',
            opacity REAL NOT NULL DEFAULT 0.7,
            pattern TEXT NOT NULL DEFAULT 'solid',
            model_file TEXT DEFAULT '',
            notes TEXT DEFAULT '',
            created_at REAL NOT NULL,
            is_active INTEGER NOT NULL DEFAULT 1
        )
        """)

        // 6. AI 분석 로그
        exec("""
        CREATE TABLE IF NOT EXISTS ai_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            mode TEXT NOT NULL,
            file_name TEXT DEFAULT '',
            detection_count INTEGER DEFAULT 0,
            fps REAL DEFAULT 0,
            notes TEXT DEFAULT ''
        )
        """)
    }

    // MARK: - 기본값 시딩

    private func seedDefaults() {
        // 설정 기본값
        let defaults: [(String, String, String)] = [
            ("volume", "1.0", "float"),
            ("playback_speed", "1.0", "float"),
            ("is_muted", "false", "bool"),
            ("render_mode", "CVDisplayLink", "string"),
            ("subtitle_offset", "0.0", "float"),
            ("ai_confidence", "0.5", "float"),
            ("window_x", "", "string"),
            ("window_y", "", "string"),
        ]
        for (key, value, type) in defaults {
            exec("INSERT OR IGNORE INTO settings (key, value, type) VALUES ('\(key)', '\(value)', '\(type)')")
        }

        // FLAME 기본 캘리브레이션
        if queryInt("SELECT COUNT(*) FROM face_calibration") == 0 {
            exec("""
            INSERT INTO face_calibration (name, uv_left_eye_x, uv_left_eye_y, uv_right_eye_x, uv_right_eye_y,
                uv_nose_x, uv_nose_y, uv_mouth_x, uv_mouth_y) VALUES
            ('FLAME 2023 기본', 0.405, 0.761, 0.598, 0.761, 0.508, 0.554, 0.506, 0.425)
            """)
        }

        // AI 프리셋 기본값
        if queryInt("SELECT COUNT(*) FROM ai_presets") == 0 {
            let presets: [(String, String, Double, Int)] = [
                ("객체 탐지 (YOLOv8n)", "기본", 0.5, 1),
                ("객체 탐지 (YOLOv8n)", "높은 정밀도", 0.7, 1),
                ("객체 탐지 (YOLOv8n)", "빠른 탐지", 0.3, 3),
                ("자세 추정 (Pose)", "기본", 0.3, 1),
                ("얼굴 랜드마크", "기본", 0.5, 1),
                ("깊이 추정 (MiDaS)", "기본", 0.5, 3),
                ("손 추적 (Hand)", "기본", 0.3, 1),
                ("텍스트 인식 (OCR)", "기본", 0.5, 2),
            ]
            for (mode, name, conf, skip) in presets {
                exec("INSERT INTO ai_presets (mode, name, confidence_threshold, frame_skip_interval, is_default) VALUES ('\(mode)', '\(name)', \(conf), \(skip), 1)")
            }
        }

        // 의류 시딩 (기존 clothing.db에서 없으면)
        if queryInt("SELECT COUNT(*) FROM clothing") == 0 {
            let now = Date().timeIntervalSince1970
            let samples: [(String, String, String, String, String)] = [
                ("파란 캐주얼 셋트", "원피스", "#3366FF", "solid", "tshirt.obj"),
                ("검정 정장", "원피스", "#333333", "solid", "suit.obj"),
                ("핑크 드레스", "원피스", "#FF6699", "solid", "dress.obj"),
                ("캐주얼 셋트 2", "원피스", "#558844", "solid", "casual2.obj"),
                ("스포츠웨어", "원피스", "#FF4444", "solid", "sportswear.obj"),
                ("페도라 모자", "모자", "#AA7744", "solid", "fedora.obj"),
            ]
            for (name, type, color, pattern, model) in samples {
                exec("INSERT INTO clothing (name, type, color_hex, pattern, model_file, created_at, is_active) VALUES ('\(name)', '\(type)', '\(color)', '\(pattern)', '\(model)', \(now), 1)")
            }
        }
    }

    // MARK: - 재생 이력

    func recordPlay(path: String, codec: String = "", audioCodec: String = "", width: Int = 0, height: Int = 0, duration: Double = 0) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let now = Date().timeIntervalSince1970
        exec("""
        INSERT INTO play_history (file_path, file_name, duration, last_played, video_codec, audio_codec, width, height)
        VALUES ('\(esc(path))', '\(esc(name))', \(duration), \(now), '\(esc(codec))', '\(esc(audioCodec))', \(width), \(height))
        ON CONFLICT(file_path) DO UPDATE SET
            play_count = play_count + 1,
            last_played = \(now),
            duration = \(duration),
            video_codec = '\(esc(codec))',
            audio_codec = '\(esc(audioCodec))',
            width = \(width), height = \(height)
        """)
    }

    func updatePlayPosition(path: String, position: Double) {
        exec("UPDATE play_history SET last_position = \(position) WHERE file_path = '\(esc(path))'")
    }

    func getLastPosition(path: String) -> Double {
        return queryDouble("SELECT last_position FROM play_history WHERE file_path = '\(esc(path))'")
    }

    func getRecentFiles(limit: Int = 10) -> [(path: String, name: String, position: Double, count: Int, date: Date)] {
        var results: [(String, String, Double, Int, Date)] = []
        var stmt: OpaquePointer?
        let sql = "SELECT file_path, file_name, last_position, play_count, last_played FROM play_history ORDER BY last_played DESC LIMIT \(limit)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append((
                String(cString: sqlite3_column_text(stmt, 0)),
                String(cString: sqlite3_column_text(stmt, 1)),
                sqlite3_column_double(stmt, 2),
                Int(sqlite3_column_int(stmt, 3)),
                Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            ))
        }
        return results
    }

    func clearHistory() { exec("DELETE FROM play_history") }

    // MARK: - 사용자 설정

    func setSetting(_ key: String, value: String) {
        exec("INSERT OR REPLACE INTO settings (key, value) VALUES ('\(key)', '\(esc(value))')")
    }

    func getSetting(_ key: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM settings WHERE key = '\(key)'", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? String(cString: sqlite3_column_text(stmt, 0)) : nil
    }

    func getFloat(_ key: String, default def: Float = 0) -> Float {
        Float(getSetting(key) ?? "") ?? def
    }

    func getBool(_ key: String, default def: Bool = false) -> Bool {
        (getSetting(key) ?? "") == "true" ? true : (getSetting(key) == "false" ? false : def)
    }

    // MARK: - AI 프리셋

    struct AIPreset {
        let id: Int64, mode: String, name: String
        let confidenceThreshold: Float, frameSkipInterval: Int
    }

    func getAIPresets(for mode: String) -> [AIPreset] {
        var results: [AIPreset] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, mode, name, confidence_threshold, frame_skip_interval FROM ai_presets WHERE mode = '\(esc(mode))' ORDER BY name", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(AIPreset(
                id: sqlite3_column_int64(stmt, 0),
                mode: String(cString: sqlite3_column_text(stmt, 1)),
                name: String(cString: sqlite3_column_text(stmt, 2)),
                confidenceThreshold: Float(sqlite3_column_double(stmt, 3)),
                frameSkipInterval: Int(sqlite3_column_int(stmt, 4))
            ))
        }
        return results
    }

    // MARK: - 얼굴 캘리브레이션

    struct FaceCalibration {
        let uvLeftEye: (x: Double, y: Double)
        let uvRightEye: (x: Double, y: Double)
        let uvNose: (x: Double, y: Double)
        let uvMouth: (x: Double, y: Double)
        let bboxExpandTop: Double, bboxExpandBottom: Double, bboxExpandSide: Double
        let posePitchBase: Double, posePitchSensitivity: Double, poseYawSensitivity: Double
    }

    func getActiveCalibration() -> FaceCalibration? {
        var stmt: OpaquePointer?
        let sql = "SELECT uv_left_eye_x, uv_left_eye_y, uv_right_eye_x, uv_right_eye_y, uv_nose_x, uv_nose_y, uv_mouth_x, uv_mouth_y, bbox_expand_top, bbox_expand_bottom, bbox_expand_side, pose_pitch_base, pose_pitch_sensitivity, pose_yaw_sensitivity FROM face_calibration WHERE is_active = 1 LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return FaceCalibration(
            uvLeftEye: (sqlite3_column_double(stmt, 0), sqlite3_column_double(stmt, 1)),
            uvRightEye: (sqlite3_column_double(stmt, 2), sqlite3_column_double(stmt, 3)),
            uvNose: (sqlite3_column_double(stmt, 4), sqlite3_column_double(stmt, 5)),
            uvMouth: (sqlite3_column_double(stmt, 6), sqlite3_column_double(stmt, 7)),
            bboxExpandTop: sqlite3_column_double(stmt, 8),
            bboxExpandBottom: sqlite3_column_double(stmt, 9),
            bboxExpandSide: sqlite3_column_double(stmt, 10),
            posePitchBase: sqlite3_column_double(stmt, 11),
            posePitchSensitivity: sqlite3_column_double(stmt, 12),
            poseYawSensitivity: sqlite3_column_double(stmt, 13)
        )
    }

    // MARK: - AI 로그

    func logAIDetection(mode: String, fileName: String = "", detectionCount: Int = 0, fps: Double = 0) {
        let now = Date().timeIntervalSince1970
        exec("INSERT INTO ai_log (timestamp, mode, file_name, detection_count, fps) VALUES (\(now), '\(esc(mode))', '\(esc(fileName))', \(detectionCount), \(fps))")
        // 1000건 초과 시 오래된 로그 삭제
        exec("DELETE FROM ai_log WHERE id NOT IN (SELECT id FROM ai_log ORDER BY timestamp DESC LIMIT 1000)")
    }

    func getAILogStats() -> [(mode: String, count: Int, avgFPS: Double)] {
        var results: [(String, Int, Double)] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT mode, COUNT(*), AVG(fps) FROM ai_log GROUP BY mode ORDER BY COUNT(*) DESC", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append((
                String(cString: sqlite3_column_text(stmt, 0)),
                Int(sqlite3_column_int(stmt, 1)),
                sqlite3_column_double(stmt, 2)
            ))
        }
        return results
    }

    // MARK: - 유틸

    private func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            if let err = sqlite3_errmsg(db) { log("[DB] \(String(cString: err))") }
        }
    }

    private func queryInt(_ sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    private func queryDouble(_ sql: String) -> Double {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_double(stmt, 0) : 0
    }

    private func esc(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }
}
