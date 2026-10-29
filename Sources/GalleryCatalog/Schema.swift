import Foundation
import GallerySQLite

/// The catalog schema, kept as one source of truth rather than a resource file: a bundle lookup that
/// can fail at runtime has no business standing between the app and its index.
public enum Schema {
    /// Bump only together with an appended `Migration`.
    public static let version: Int32 = 4

    /// A fresh install gets this; an existing library gets `migrations` applied on top of its own version.
    public static let create = """
    CREATE TABLE folder_source (
      id            INTEGER PRIMARY KEY,
      root_rel      TEXT    NOT NULL,
      volume_id     TEXT    NOT NULL,
      display_name  TEXT    NOT NULL,
      bookmark      BLOB,
      state         INTEGER NOT NULL DEFAULT 0,
      watcher       INTEGER NOT NULL DEFAULT 0,
      last_event_id INTEGER,
      last_sweep_ns INTEGER,
      last_scan_ns  INTEGER,
      is_included   INTEGER NOT NULL DEFAULT 1,
      UNIQUE(volume_id, root_rel)
    );

    CREATE TABLE media (
      id            INTEGER PRIMARY KEY,
      src_id        INTEGER NOT NULL REFERENCES folder_source(id) ON DELETE CASCADE,
      rel_path      TEXT    NOT NULL,
      parent_rel    TEXT    NOT NULL DEFAULT '',
      name          TEXT    NOT NULL,
      ext           TEXT,
      volume_id     TEXT    NOT NULL,
      doc_id        INTEGER,
      res_id        INTEGER,
      stat_hash     INTEGER NOT NULL,
      size_bytes    INTEGER NOT NULL DEFAULT 0,
      mtime_ns      INTEGER,
      ctime_ns      INTEGER,
      added_ns      INTEGER NOT NULL,
      uttype        TEXT    NOT NULL DEFAULT '',
      kind          INTEGER NOT NULL DEFAULT 2,
      subtype       INTEGER NOT NULL DEFAULT 0,
      stage         INTEGER NOT NULL DEFAULT 0,
      err_code      INTEGER NOT NULL DEFAULT 0,
      px_w          INTEGER,
      px_h          INTEGER,
      orientation   INTEGER,
      color_space   TEXT,
      duration_us   INTEGER,
      codec         TEXT,
      cap_utc       REAL    NOT NULL DEFAULT 0,
      cap_wall      REAL    NOT NULL DEFAULT 0,
      cap_day       INTEGER NOT NULL DEFAULT 0,
      cap_month     INTEGER NOT NULL DEFAULT 0,
      cap_tz        TEXT,
      cap_src       INTEGER NOT NULL DEFAULT 5,
      lat           REAL,
      lon           REAL,
      has_gps       INTEGER NOT NULL DEFAULT 0,
      place_key     TEXT,
      cluster_id    INTEGER,
      device        TEXT,
      lens          TEXT,
      meta_json     TEXT,
      search_text   TEXT,
      is_offline    INTEGER NOT NULL DEFAULT 0,
      trash         INTEGER NOT NULL DEFAULT 0,
      -- Analysis (phase A). A stage of its own rather than a new IndexStage: `stage` gates pass A, pass B,
      -- the progress fractions and the cover query, and none of those should learn about Vision.
      analysis_stage    INTEGER NOT NULL DEFAULT 0,
      analysis_attempts INTEGER NOT NULL DEFAULT 0,
      aesthetic         REAL    NOT NULL DEFAULT 0,
      is_utility        INTEGER NOT NULL DEFAULT 0,
      -- Derived search text, owned by the analysis pass. Separate from `search_text` (which pass B rewrites
      -- wholesale from the file's own vocabulary) so re-analysis is idempotent and rank weights differ.
      search_tags       TEXT,
      search_ocr        TEXT,
      -- A title the user wrote, written into the file and re-derived by pass B. Appended, not inserted:
      -- FTS column order is positional and every weight in `CatalogReader.search` names an index.
      title             TEXT
    );

    -- Identity, not path, is the primary key of a photograph. Two files that swap names inside one
    -- folder are two updates to the same rows, never a delete and an insert, so favorites, thumbnails
    -- and cluster membership all ride through the rename.
    CREATE UNIQUE INDEX media_identity_path ON media(src_id, rel_path);
    CREATE UNIQUE INDEX media_identity_doc  ON media(volume_id, doc_id) WHERE doc_id IS NOT NULL;
    CREATE UNIQUE INDEX media_identity_res  ON media(volume_id, res_id) WHERE doc_id IS NULL AND res_id IS NOT NULL;

    -- Every browse path in the app is one of these five seeks. `id` is appended so a burst of identical
    -- timestamps still yields a total order, which is what makes keyset paging exact.
    CREATE INDEX media_capture      ON media(cap_utc DESC, id DESC);
    CREATE INDEX media_added        ON media(added_ns DESC, id DESC);
    CREATE INDEX media_day          ON media(cap_day, id);
    CREATE INDEX media_folder       ON media(src_id, parent_rel, id);
    CREATE INDEX media_kind_capture ON media(kind, cap_utc DESC, id DESC);
    CREATE INDEX media_name         ON media(name COLLATE NOCASE, id);
    CREATE INDEX media_gps          ON media(lat, lon) WHERE has_gps = 1;
    CREATE INDEX media_cluster      ON media(cluster_id) WHERE cluster_id IS NOT NULL;
    CREATE INDEX media_place        ON media(place_key) WHERE place_key IS NOT NULL;
    CREATE INDEX media_trash        ON media(trash, id) WHERE trash <> 0;
    -- The pass-B work queue, as a partial index: 100k finished rows must not appear in it at all.
    CREATE INDEX media_pending      ON media(stage, src_id, id) WHERE stage < 3;

    -- The analysis cursor. Claiming is the state transition (analysis_stage 0 -> 1), so there is no queue
    -- table to keep in step with the rows it describes.
    CREATE INDEX media_analysis_pending ON media(analysis_stage, stage, cap_day DESC, id DESC)
      WHERE analysis_stage < 2 AND trash = 0;
    CREATE INDEX media_aesthetic ON media(aesthetic DESC, id DESC);
    CREATE INDEX media_folder_cover ON media(src_id, parent_rel, aesthetic DESC, id DESC);

    -- Favorites are a set of ids, not a column on the big table: toggling one must not rewrite a media
    -- row, and the upsert that follows a rename must not be able to lose one.
    CREATE TABLE favorite (
      media_id  INTEGER PRIMARY KEY REFERENCES media(id) ON DELETE CASCADE,
      added_ns  INTEGER NOT NULL
    );

    -- The app cannot enumerate ~/.Trash from a sandbox, so the ledger is the only record of what was
    -- deleted and where it came from. It is written before the filesystem operation, which makes it the
    -- undo log rather than a report.
    CREATE TABLE trash_ledger (
      id           INTEGER PRIMARY KEY,
      media_id     INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
      src_id       INTEGER NOT NULL,
      from_rel     TEXT    NOT NULL,
      from_volume  TEXT    NOT NULL,
      to_rel       TEXT,
      mode         INTEGER NOT NULL DEFAULT 0,
      state        INTEGER NOT NULL DEFAULT 1,
      byte_size    INTEGER NOT NULL DEFAULT 0,
      trashed_ns   INTEGER NOT NULL,
      restored_ns  INTEGER,
      restore_err  TEXT,
      -- v4: when a backup finished, and the stat hash the file had afterwards. Revert is refused when the
      -- file has changed since, because reverting would undo someone else's edit.
      completed_ns     INTEGER,
      result_stat_hash INTEGER
    );
    CREATE INDEX ledger_media ON trash_ledger(media_id);
    CREATE INDEX ledger_state ON trash_ledger(state, trashed_ns DESC);

    CREATE TABLE location_cluster (
      id           INTEGER PRIMARY KEY,
      center_lat   REAL    NOT NULL,
      center_lon   REAL    NOT NULL,
      radius_m     REAL    NOT NULL DEFAULT 0,
      item_count   INTEGER NOT NULL DEFAULT 0,
      level        INTEGER NOT NULL DEFAULT 4,
      name         TEXT,
      locality     TEXT,
      sublocality  TEXT,
      admin_area   TEXT,
      country      TEXT,
      iso_country  TEXT,
      place_key    TEXT,
      geocoded_ns  INTEGER
    );
    CREATE TABLE cluster_member (
      cluster_id  INTEGER NOT NULL REFERENCES location_cluster(id) ON DELETE CASCADE,
      media_id    INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
      PRIMARY KEY (cluster_id, media_id)
    );
    CREATE INDEX cluster_member_media ON cluster_member(media_id);

    CREATE TABLE geocode_cache (
      key        TEXT PRIMARY KEY,
      payload    TEXT    NOT NULL,
      fetched_ns INTEGER NOT NULL,
      did_fail   INTEGER NOT NULL DEFAULT 0
    );

    -- Events and clusters are the two album kinds that are materialised rather than derived per query:
    -- clustering is O(n log n) geometry with an async geocode dependency, and an album id that changes
    -- on every recompute would break the sidebar selection it is supposed to be stable across.
    CREATE TABLE event (
      id          INTEGER PRIMARY KEY,
      key_id      INTEGER NOT NULL UNIQUE,
      title       TEXT    NOT NULL,
      src_id      INTEGER,
      first_ns    INTEGER NOT NULL,
      last_ns     INTEGER NOT NULL,
      item_count  INTEGER NOT NULL DEFAULT 0,
      centroid_lat REAL,
      centroid_lon REAL,
      place_key   TEXT
    );
    CREATE TABLE event_member (
      event_id  INTEGER NOT NULL REFERENCES event(id) ON DELETE CASCADE,
      media_id  INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
      PRIMARY KEY (event_id, media_id)
    );
    CREATE INDEX event_member_media ON event_member(media_id);

    -- What the on-device analyser saw, and the stamp it saw it at. One row per photograph, not a versioned
    -- history: analysis is the answer to "what is in this file", so changed bytes make the row pending again
    -- rather than creating a second one.
    CREATE TABLE media_analysis (
      media_id       INTEGER PRIMARY KEY REFERENCES media(id) ON DELETE CASCADE,
      stat_hash      INTEGER NOT NULL,
      version        INTEGER NOT NULL,
      revision       TEXT    NOT NULL,
      analyzed_ns    INTEGER NOT NULL,
      labels_json    TEXT,
      ocr_chars      INTEGER NOT NULL DEFAULT 0,
      ocr_blocks     INTEGER NOT NULL DEFAULT 0,
      ocr_accurate   INTEGER NOT NULL DEFAULT 0,
      dhash          INTEGER,
      print_revision INTEGER,
      print_dims     INTEGER,
      -- Kept only for rows that land in a duplicate group: a print is ~8 kB, and 100k of them would be
      -- 800 MB of user storage for a decision that has already been made.
      print_data     BLOB,
      face_count     INTEGER NOT NULL DEFAULT 0,
      frames         INTEGER NOT NULL DEFAULT 0
    ) WITHOUT ROWID;

    -- The album vocabulary. Denormalised aesthetic so one tag's cover is one index seek.
    CREATE TABLE media_tag (
      media_id  INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
      slug      TEXT    NOT NULL,
      aesthetic REAL    NOT NULL DEFAULT 0,
      PRIMARY KEY (media_id, slug)
    ) WITHOUT ROWID;
    CREATE INDEX media_tag_slug ON media_tag(slug, aesthetic DESC, media_id);

    CREATE TABLE face_cluster (
      id             INTEGER PRIMARY KEY,
      revision       INTEGER NOT NULL,
      name           TEXT,
      auto_index     INTEGER NOT NULL DEFAULT 0,
      centroid       BLOB    NOT NULL,
      dims           INTEGER NOT NULL,
      face_count     INTEGER NOT NULL DEFAULT 0,
      cover_media_id INTEGER REFERENCES media(id) ON DELETE SET NULL,
      cover_face_id  INTEGER,
      hidden         INTEGER NOT NULL DEFAULT 0,
      created_ns     INTEGER NOT NULL,
      named_ns       INTEGER
    );
    CREATE INDEX face_cluster_people ON face_cluster(face_count DESC, id) WHERE hidden = 0;

    CREATE TABLE face (
      id          INTEGER PRIMARY KEY,
      media_id    INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
      frame       INTEGER NOT NULL DEFAULT 0,
      x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL,
      confidence  REAL NOT NULL DEFAULT 0,
      quality     REAL NOT NULL DEFAULT 0,
      embedding   BLOB    NOT NULL,
      dims        INTEGER NOT NULL,
      cluster_id  INTEGER REFERENCES face_cluster(id) ON DELETE SET NULL,
      detected_ns INTEGER NOT NULL
    );
    CREATE INDEX face_media ON face(media_id);
    CREATE INDEX face_by_cluster ON face(cluster_id) WHERE cluster_id IS NOT NULL;

    CREATE TABLE duplicate_group (
      id           INTEGER PRIMARY KEY,
      member_count INTEGER NOT NULL DEFAULT 0,
      best_id      INTEGER REFERENCES media(id) ON DELETE SET NULL,
      created_ns   INTEGER NOT NULL,
      updated_ns   INTEGER NOT NULL
    );
    CREATE TABLE duplicate_member (
      group_id  INTEGER NOT NULL REFERENCES duplicate_group(id) ON DELETE CASCADE,
      media_id  INTEGER NOT NULL REFERENCES media(id) ON DELETE CASCADE,
      distance  INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (group_id, media_id)
    );
    CREATE INDEX duplicate_member_media ON duplicate_member(media_id);

    CREATE TABLE thumbnail_cache (
      media_id     INTEGER NOT NULL,
      bucket       INTEGER NOT NULL,
      mtime_ns     INTEGER NOT NULL,
      path         TEXT    NOT NULL,
      byte_size    INTEGER NOT NULL DEFAULT 0,
      last_used_ns INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (media_id, bucket, mtime_ns)
    ) WITHOUT ROWID;
    CREATE INDEX thumb_lru ON thumbnail_cache(last_used_ns);

    -- Durable work, not a task list: a scan interrupted by a crash or a quit resumes from here.
    -- `rank` is last rather than in the middle because v2 adds it with `ALTER TABLE`, which appends: the two
    -- paths have to leave the table with the same columns in the same order.
    CREATE TABLE scan_queue (
      id          INTEGER PRIMARY KEY,
      src_id      INTEGER NOT NULL REFERENCES folder_source(id) ON DELETE CASCADE,
      media_id    INTEGER,
      rel_path    TEXT,
      kind        INTEGER NOT NULL DEFAULT 1,
      priority    INTEGER NOT NULL DEFAULT 0,
      enqueued_ns INTEGER NOT NULL,
      attempts    INTEGER NOT NULL DEFAULT 0,
      last_error  TEXT,
      -- Whole days of `mtime`, copied in at enqueue time: `priority` is *why* this row matters (the viewport
      -- jumps the queue) and `rank` is *when* the file is, so the claim order is viewport first, then newest,
      -- then the tail. Joined from `media` at claim time instead, it would sort 100k rows per hop.
      rank        INTEGER NOT NULL DEFAULT 0
    );
    -- Two partial unique keys rather than one `UNIQUE(src_id, kind, media_id, rel_path)`: a plain unique
    -- index treats NULL as distinct, so the media-id entries (rel_path NULL) and the path entries
    -- (media_id NULL) would each re-insert a duplicate on every re-enqueue, and re-enqueueing after a
    -- crash is the whole point.
    CREATE UNIQUE INDEX queue_by_media ON scan_queue(src_id, kind, media_id) WHERE media_id IS NOT NULL;
    CREATE UNIQUE INDEX queue_by_path  ON scan_queue(src_id, kind, rel_path) WHERE rel_path IS NOT NULL;
    CREATE INDEX queue_claim ON scan_queue(priority DESC, rank DESC, enqueued_ns ASC, id);

    CREATE TABLE setting (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );

    -- External-content FTS5 kept in step by triggers rather than by application code: after a
    -- kill -9 mid-batch, the index is still consistent with the table it describes.
    --
    -- Two derived columns since v3. `search_tags` and `search_ocr` carry a curated judgement and a noisy
    -- transcription respectively, which is why they rank differently from the file's own vocabulary.
    CREATE VIRTUAL TABLE media_fts USING fts5(
      name, place_key, device, lens, search_text, search_tags, search_ocr, title,
      content='media', content_rowid='id',
      tokenize='porter unicode61 remove_diacritics 2'
    );

    CREATE TRIGGER media_fts_ai AFTER INSERT ON media BEGIN
      INSERT INTO media_fts(rowid, name, place_key, device, lens, search_text, search_tags, search_ocr,
                            title)
      VALUES (new.id, new.name, new.place_key, new.device, new.lens, new.search_text, new.search_tags,
              new.search_ocr, new.title);
    END;

    CREATE TRIGGER media_fts_ad AFTER DELETE ON media BEGIN
      INSERT INTO media_fts(media_fts, rowid, name, place_key, device, lens, search_text, search_tags,
                            search_ocr, title)
      VALUES ('delete', old.id, old.name, old.place_key, old.device, old.lens, old.search_text,
              old.search_tags, old.search_ocr, old.title);
    END;

    CREATE TRIGGER media_fts_au AFTER UPDATE OF name, place_key, device, lens, search_text, search_tags,
                                             search_ocr, title ON media BEGIN
      INSERT INTO media_fts(media_fts, rowid, name, place_key, device, lens, search_text, search_tags,
                            search_ocr, title)
      VALUES ('delete', old.id, old.name, old.place_key, old.device, old.lens, old.search_text,
              old.search_tags, old.search_ocr, old.title);
      INSERT INTO media_fts(rowid, name, place_key, device, lens, search_text, search_tags, search_ocr,
                            title)
      VALUES (new.id, new.name, new.place_key, new.device, new.lens, new.search_text, new.search_tags,
              new.search_ocr, new.title);
    END;
    """

    /// Rebuild the FTS index from the media table. Used after a migration that added columns, and
    /// available to the Problems view as a user-triggerable repair.
    public static let rebuildFTS = "INSERT INTO media_fts(media_fts) VALUES ('rebuild')"
}
