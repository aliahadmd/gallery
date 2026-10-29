import Foundation
import GallerySQLite

/// Undo the release ladder one version at a time.
///
/// A migration test that writes `user_version = 1` onto a fresh database is testing nothing: the tables are
/// already current, so the first `ALTER` collides. These helpers put the schema back the way that release
/// actually left it, so the ladder runs for real.
extension SQLiteHandle {
    /// Everything v2, v3, v4 and v5 added is removed; `scan_queue` has no `rank` and FTS knows five columns.
    func downgradeToV1() throws {
        try downgradeToV4()
        try exec("""
        DROP TRIGGER media_fts_ai;
        DROP TRIGGER media_fts_ad;
        DROP TRIGGER media_fts_au;
        DROP TABLE media_fts;
        CREATE VIRTUAL TABLE media_fts USING fts5(
          name, place_key, device, lens, search_text,
          content='media', content_rowid='id',
          tokenize='porter unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER media_fts_ai AFTER INSERT ON media BEGIN
          INSERT INTO media_fts(rowid, name, place_key, device, lens, search_text)
          VALUES (new.id, new.name, new.place_key, new.device, new.lens, new.search_text);
        END;
        CREATE TRIGGER media_fts_ad AFTER DELETE ON media BEGIN
          INSERT INTO media_fts(media_fts, rowid, name, place_key, device, lens, search_text)
          VALUES ('delete', old.id, old.name, old.place_key, old.device, old.lens, old.search_text);
        END;
        CREATE TRIGGER media_fts_au AFTER UPDATE OF name, place_key, device, lens, search_text ON media BEGIN
          INSERT INTO media_fts(media_fts, rowid, name, place_key, device, lens, search_text)
          VALUES ('delete', old.id, old.name, old.place_key, old.device, old.lens, old.search_text);
          INSERT INTO media_fts(rowid, name, place_key, device, lens, search_text)
          VALUES (new.id, new.name, new.place_key, new.device, new.lens, new.search_text);
        END;
        INSERT INTO media_fts(media_fts) VALUES ('rebuild');

        DROP INDEX media_analysis_pending;
        DROP INDEX media_aesthetic;
        DROP INDEX media_folder_cover;
        DROP TABLE media_tag;
        DROP TABLE face;
        DROP TABLE face_cluster;
        DROP TABLE duplicate_member;
        DROP TABLE duplicate_group;
        DROP TABLE media_analysis;
        ALTER TABLE media DROP COLUMN search_ocr;
        ALTER TABLE media DROP COLUMN search_tags;
        ALTER TABLE media DROP COLUMN is_utility;
        ALTER TABLE media DROP COLUMN aesthetic;
        ALTER TABLE media DROP COLUMN analysis_attempts;
        ALTER TABLE media DROP COLUMN analysis_stage;

        ALTER TABLE media DROP COLUMN title;
        ALTER TABLE trash_ledger DROP COLUMN result_stat_hash;
        ALTER TABLE trash_ledger DROP COLUMN completed_ns;

        DROP INDEX queue_claim;
        ALTER TABLE scan_queue DROP COLUMN rank;
        CREATE INDEX queue_claim ON scan_queue(priority DESC, enqueued_ns ASC, id);
        """)
    }

    /// A v3 database: the analysis tables and the seven-column index are there; v4's title and ledger
    /// columns are not.
    func downgradeToV3() throws {
        try downgradeToV4()
        try exec("""
        DROP TRIGGER media_fts_ai;
        DROP TRIGGER media_fts_ad;
        DROP TRIGGER media_fts_au;
        DROP TABLE media_fts;
        CREATE VIRTUAL TABLE media_fts USING fts5(
          name, place_key, device, lens, search_text, search_tags, search_ocr,
          content='media', content_rowid='id',
          tokenize='porter unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER media_fts_ai AFTER INSERT ON media BEGIN
          INSERT INTO media_fts(rowid, name, place_key, device, lens, search_text, search_tags, search_ocr)
          VALUES (new.id, new.name, new.place_key, new.device, new.lens, new.search_text, new.search_tags,
                  new.search_ocr);
        END;
        CREATE TRIGGER media_fts_ad AFTER DELETE ON media BEGIN
          INSERT INTO media_fts(media_fts, rowid, name, place_key, device, lens, search_text, search_tags,
                                search_ocr)
          VALUES ('delete', old.id, old.name, old.place_key, old.device, old.lens, old.search_text,
                  old.search_tags, old.search_ocr);
        END;
        CREATE TRIGGER media_fts_au AFTER UPDATE OF name, place_key, device, lens, search_text, search_tags,
                                                 search_ocr ON media BEGIN
          INSERT INTO media_fts(media_fts, rowid, name, place_key, device, lens, search_text, search_tags,
                                search_ocr)
          VALUES ('delete', old.id, old.name, old.place_key, old.device, old.lens, old.search_text,
                  old.search_tags, old.search_ocr);
          INSERT INTO media_fts(rowid, name, place_key, device, lens, search_text, search_tags, search_ocr)
          VALUES (new.id, new.name, new.place_key, new.device, new.lens, new.search_text, new.search_tags,
                  new.search_ocr);
        END;
        INSERT INTO media_fts(media_fts) VALUES ('rebuild');

        ALTER TABLE media DROP COLUMN title;
        ALTER TABLE trash_ledger DROP COLUMN result_stat_hash;
        ALTER TABLE trash_ledger DROP COLUMN completed_ns;
        """)
    }

    /// A v4 database: v5's category columns, tables and rename journal are gone; FTS is the eight-column
    /// index v4 shipped.
    func downgradeToV4() throws {
        try exec("""
        DROP INDEX media_category_pending;
        DROP INDEX media_category_lookup;
        DROP TABLE rename_journal;
        DROP TABLE category_feedback;
        DROP TABLE media_category;
        ALTER TABLE media DROP COLUMN category_attempts;
        ALTER TABLE media DROP COLUMN category_stage;
        ALTER TABLE media DROP COLUMN category_confidence;
        ALTER TABLE media DROP COLUMN category;
        """)
    }

    /// A v2 database: `rank` is back, nothing from v3 exists.
    func downgradeToV2() throws {
        try downgradeToV1()
        try exec("""
        ALTER TABLE scan_queue ADD COLUMN rank INTEGER NOT NULL DEFAULT 0;
        DROP INDEX queue_claim;
        CREATE INDEX queue_claim ON scan_queue(priority DESC, rank DESC, enqueued_ns ASC, id);
        """)
    }
}
