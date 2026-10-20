import Foundation

/// Schema design rules:
///  1. `message` rows are the ground truth. They are write-once (a trigger rejects edits).
///  2. Everything else (fts, chunk, vec, memory, entity, summary, asset text) is *derived* and rebuildable.
///  3. Derived rows reference originals by id and carry verbatim quotes, so any conclusion can be traced back.
public enum Schema {
    public static let currentVersion = 1

    static let v1: [String] = [
        """
        CREATE TABLE source(
          id INTEGER PRIMARY KEY,
          kind TEXT NOT NULL,              -- chatgpt_export | claude_export | generic | app_chat | photos | files
          name TEXT NOT NULL,
          external_id TEXT,
          imported_at REAL NOT NULL,
          fingerprint TEXT,
          meta TEXT,
          UNIQUE(kind, external_id)
        )
        """,
        """
        CREATE TABLE conversation(
          id INTEGER PRIMARY KEY,
          source_id INTEGER NOT NULL REFERENCES source(id),
          external_id TEXT,
          title TEXT,
          created_at REAL,
          updated_at REAL,
          origin TEXT NOT NULL DEFAULT 'imported',   -- imported | local
          message_count INTEGER NOT NULL DEFAULT 0,
          meta TEXT,
          UNIQUE(source_id, external_id)
        )
        """,
        """
        CREATE TABLE message(
          id INTEGER PRIMARY KEY,
          conversation_id INTEGER NOT NULL REFERENCES conversation(id),
          seq INTEGER NOT NULL,
          role TEXT NOT NULL,                        -- user | assistant | system | tool
          text TEXT NOT NULL,
          created_at REAL NOT NULL,
          external_id TEXT,
          content_hash INTEGER NOT NULL,
          model TEXT,                                -- model that produced an assistant message
          locality TEXT NOT NULL DEFAULT 'imported', -- local | cloud | imported
          meta TEXT
        )
        """,
        "CREATE UNIQUE INDEX message_conv_seq ON message(conversation_id, seq)",
        "CREATE UNIQUE INDEX message_conv_ext ON message(conversation_id, external_id) WHERE external_id IS NOT NULL",
        "CREATE INDEX message_time ON message(created_at)",
        """
        CREATE TRIGGER message_immutable BEFORE UPDATE OF text, role, created_at, conversation_id, seq ON message
        BEGIN SELECT RAISE(ABORT, 'archive messages are immutable'); END
        """,
        """
        CREATE VIRTUAL TABLE message_fts USING fts5(
          text, content='message', content_rowid='id',
          tokenize='unicode61 remove_diacritics 2'
        )
        """,
        """
        CREATE TRIGGER message_ai AFTER INSERT ON message BEGIN
          INSERT INTO message_fts(rowid, text) VALUES (new.id, new.text);
        END
        """,
        """
        CREATE TRIGGER message_ad AFTER DELETE ON message BEGIN
          INSERT INTO message_fts(message_fts, rowid, text) VALUES('delete', old.id, old.text);
        END
        """,
        "CREATE VIRTUAL TABLE message_vocab USING fts5vocab(message_fts, 'row')",
        """
        CREATE VIRTUAL TABLE conversation_fts USING fts5(
          title, content='conversation', content_rowid='id', tokenize='unicode61 remove_diacritics 2'
        )
        """,
        """
        CREATE TRIGGER conversation_ai AFTER INSERT ON conversation BEGIN
          INSERT INTO conversation_fts(rowid, title) VALUES (new.id, COALESCE(new.title,''));
        END
        """,
        """
        CREATE TRIGGER conversation_ad AFTER DELETE ON conversation BEGIN
          INSERT INTO conversation_fts(conversation_fts, rowid, title) VALUES('delete', old.id, COALESCE(old.title,''));
        END
        """,

        // ---- retrieval units: contiguous message ranges (or a slice of one very long message) ----
        """
        CREATE TABLE chunk(
          id INTEGER PRIMARY KEY,
          conversation_id INTEGER NOT NULL,
          first_msg INTEGER NOT NULL,
          last_msg INTEGER NOT NULL,
          first_seq INTEGER NOT NULL,
          last_seq INTEGER NOT NULL,
          char_start INTEGER,               -- set only for slices of one long message
          char_end INTEGER,
          t0 REAL NOT NULL,
          t1 REAL NOT NULL,
          tokens INTEGER NOT NULL,
          embedded INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX chunk_conv ON chunk(conversation_id, first_seq)",
        "CREATE INDEX chunk_pending ON chunk(id) WHERE embedded = 0",
        "CREATE INDEX chunk_msg ON chunk(first_msg)",

        // ---- vector index: IVF-flat, int8 scalar quantisation. `space` = (embedder, item kind). ----
        """
        CREATE TABLE vec_space(
          space INTEGER PRIMARY KEY,
          name TEXT NOT NULL,
          embedder TEXT NOT NULL,
          dim INTEGER NOT NULL,
          item_kind TEXT NOT NULL,          -- chunk | asset | memory
          trained_count INTEGER NOT NULL DEFAULT 0,
          nlist INTEGER NOT NULL DEFAULT 1,
          nprobe INTEGER,
          measured_recall REAL
        )
        """,
        """
        CREATE TABLE vec_centroid(
          space INTEGER NOT NULL, list INTEGER NOT NULL, centroid BLOB NOT NULL, count INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(space, list)
        ) WITHOUT ROWID
        """,
        // Vectors live in contiguous blocks (one SQLite row per ~128 vectors) so a scan costs memory bandwidth, not per-row overhead.
        """
        CREATE TABLE vec_block(
          space INTEGER NOT NULL, list INTEGER NOT NULL, block INTEGER NOT NULL, n INTEGER NOT NULL,
          ids BLOB NOT NULL, scales BLOB NOT NULL, v BLOB NOT NULL,
          PRIMARY KEY(space, list, block)
        ) WITHOUT ROWID
        """,
        "CREATE TABLE vec_purge(space INTEGER NOT NULL, item_id INTEGER NOT NULL, PRIMARY KEY(space, item_id)) WITHOUT ROWID",

        // ---- entities and relationships ----
        """
        CREATE TABLE entity(
          id INTEGER PRIMARY KEY,
          kind TEXT NOT NULL,               -- person | project | place | org | topic | event | thing
          name TEXT NOT NULL,
          description TEXT,
          first_seen REAL, last_seen REAL,
          created_by TEXT NOT NULL DEFAULT 'extractor',
          merged_into INTEGER REFERENCES entity(id),
          meta TEXT
        )
        """,
        """
        CREATE TABLE entity_alias(
          entity_id INTEGER NOT NULL REFERENCES entity(id) ON DELETE CASCADE,
          alias TEXT NOT NULL,              -- lowercased
          PRIMARY KEY(alias, entity_id)
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE entity_mention(
          entity_id INTEGER NOT NULL REFERENCES entity(id) ON DELETE CASCADE,
          message_id INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
          conversation_id INTEGER NOT NULL,
          PRIMARY KEY(entity_id, message_id)
        ) WITHOUT ROWID
        """,
        "CREATE INDEX entity_mention_conv ON entity_mention(conversation_id, entity_id)",
        """
        CREATE TABLE relation(
          id INTEGER PRIMARY KEY,
          subject INTEGER NOT NULL REFERENCES entity(id) ON DELETE CASCADE,
          predicate TEXT NOT NULL,
          object INTEGER REFERENCES entity(id) ON DELETE CASCADE,
          object_value TEXT,
          valid_from REAL, valid_to REAL,
          confidence REAL NOT NULL DEFAULT 0.5,
          memory_id INTEGER
        )
        """,
        "CREATE INDEX relation_subject ON relation(subject, predicate)",

        // ---- derived memory. Every row must be explainable via memory_evidence. ----
        """
        CREATE TABLE memory(
          id INTEGER PRIMARY KEY,
          kind TEXT NOT NULL,        -- fact | preference | decision | goal | constraint | commitment | open_thread | event | observation | hypothesis
          epistemic TEXT NOT NULL,   -- stated (user said it) | observed (seen in behaviour/text) | inferred (a guess)
          attribute TEXT,            -- normalised key for reconciliation, e.g. "employer"
          cardinality TEXT NOT NULL DEFAULT 'single',   -- single | multi
          subject INTEGER REFERENCES entity(id),        -- NULL == the user
          text TEXT NOT NULL,
          value TEXT,
          confidence REAL NOT NULL,
          status TEXT NOT NULL DEFAULT 'active',        -- active | superseded | disputed | retracted
          valid_from REAL, valid_to REAL,
          scope_conversation INTEGER,                   -- conversation-local constraint/decision/thread
          standing INTEGER NOT NULL DEFAULT 0,          -- always-relevant instruction-like preference
          user_state TEXT NOT NULL DEFAULT 'none',      -- none | confirmed | corrected | rejected
          supersedes INTEGER REFERENCES memory(id),
          created_by TEXT NOT NULL,                     -- rule | llm:<model> | user
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          embedded INTEGER NOT NULL DEFAULT 0,
          meta TEXT
        )
        """,
        "CREATE INDEX memory_attr ON memory(subject, attribute, status)",
        "CREATE INDEX memory_status ON memory(status, kind)",
        "CREATE INDEX memory_conv ON memory(scope_conversation) WHERE scope_conversation IS NOT NULL",
        """
        CREATE VIRTUAL TABLE memory_fts USING fts5(text, content='memory', content_rowid='id', tokenize='porter unicode61 remove_diacritics 2')
        """,
        """
        CREATE TRIGGER memory_ai AFTER INSERT ON memory BEGIN INSERT INTO memory_fts(rowid, text) VALUES (new.id, new.text); END
        """,
        """
        CREATE TRIGGER memory_ad AFTER DELETE ON memory BEGIN INSERT INTO memory_fts(memory_fts, rowid, text) VALUES('delete', old.id, old.text); END
        """,
        """
        CREATE TRIGGER memory_au AFTER UPDATE OF text ON memory BEGIN
          INSERT INTO memory_fts(memory_fts, rowid, text) VALUES('delete', old.id, old.text);
          INSERT INTO memory_fts(rowid, text) VALUES (new.id, new.text);
        END
        """,
        """
        CREATE TABLE memory_evidence(
          memory_id INTEGER NOT NULL REFERENCES memory(id) ON DELETE CASCADE,
          message_id INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
          role TEXT NOT NULL DEFAULT 'supports',   -- supports | contradicts | origin
          speaker TEXT NOT NULL,                   -- role of the quoted message
          quote TEXT NOT NULL,                     -- verbatim substring of the message (verified on write)
          created_at REAL NOT NULL,
          PRIMARY KEY(memory_id, message_id, role)
        ) WITHOUT ROWID
        """,
        "CREATE INDEX memory_evidence_msg ON memory_evidence(message_id)",
        """
        CREATE TABLE memory_event(
          id INTEGER PRIMARY KEY,
          memory_id INTEGER NOT NULL,       -- no FK: the audit trail survives deletion
          at REAL NOT NULL,
          action TEXT NOT NULL,             -- created | reinforced | superseded | disputed | corrected | confirmed | rejected | retracted | deleted | source_erased
          actor TEXT NOT NULL,              -- rule | llm:<model> | user
          detail TEXT
        )
        """,
        "CREATE INDEX memory_event_mem ON memory_event(memory_id)",

        // ---- navigation summaries: pointers into the archive, never a substitute for it ----
        """
        CREATE TABLE summary(
          id INTEGER PRIMARY KEY,
          conversation_id INTEGER NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
          level INTEGER NOT NULL DEFAULT 0,
          first_seq INTEGER NOT NULL, last_seq INTEGER NOT NULL,
          first_msg INTEGER NOT NULL, last_msg INTEGER NOT NULL,
          text TEXT NOT NULL,
          model TEXT,
          created_at REAL NOT NULL
        )
        """,
        "CREATE INDEX summary_conv ON summary(conversation_id, level, first_seq)",

        // ---- photos and files ----
        """
        CREATE TABLE asset(
          id INTEGER PRIMARY KEY,
          source_id INTEGER NOT NULL REFERENCES source(id),
          kind TEXT NOT NULL,              -- photo | image | document | text
          external_id TEXT NOT NULL,       -- PHAsset.localIdentifier, bookmark key, or relative path
          name TEXT,
          mime TEXT,
          created_at REAL,                 -- capture / creation time
          added_at REAL NOT NULL,
          width INTEGER, height INTEGER,
          latitude REAL, longitude REAL, place TEXT,
          text TEXT,                       -- OCR / extracted text
          caption TEXT,
          labels TEXT,
          bytes INTEGER,
          status TEXT NOT NULL DEFAULT 'indexed',   -- pending | indexed | inaccessible | removed
          meta TEXT,
          UNIQUE(source_id, external_id)
        )
        """,
        "CREATE INDEX asset_time ON asset(created_at)",
        """
        CREATE VIRTUAL TABLE asset_fts USING fts5(name, text, caption, labels, place, content='asset', content_rowid='id', tokenize='porter unicode61 remove_diacritics 2')
        """,
        """
        CREATE TRIGGER asset_ai AFTER INSERT ON asset BEGIN
          INSERT INTO asset_fts(rowid, name, text, caption, labels, place) VALUES (new.id, COALESCE(new.name,''), COALESCE(new.text,''), COALESCE(new.caption,''), COALESCE(new.labels,''), COALESCE(new.place,''));
        END
        """,
        """
        CREATE TRIGGER asset_ad AFTER DELETE ON asset BEGIN
          INSERT INTO asset_fts(asset_fts, rowid, name, text, caption, labels, place) VALUES('delete', old.id, COALESCE(old.name,''), COALESCE(old.text,''), COALESCE(old.caption,''), COALESCE(old.labels,''), COALESCE(old.place,''));
        END
        """,
        """
        CREATE TRIGGER asset_au AFTER UPDATE OF name, text, caption, labels, place ON asset BEGIN
          INSERT INTO asset_fts(asset_fts, rowid, name, text, caption, labels, place) VALUES('delete', old.id, COALESCE(old.name,''), COALESCE(old.text,''), COALESCE(old.caption,''), COALESCE(old.labels,''), COALESCE(old.place,''));
          INSERT INTO asset_fts(rowid, name, text, caption, labels, place) VALUES (new.id, COALESCE(new.name,''), COALESCE(new.text,''), COALESCE(new.caption,''), COALESCE(new.labels,''), COALESCE(new.place,''));
        END
        """,
        """
        CREATE TABLE asset_link(
          asset_id INTEGER NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
          message_id INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
          conversation_id INTEGER NOT NULL,
          kind TEXT NOT NULL,              -- attached (explicit in the export) | time_near (inferred from timestamps)
          score REAL NOT NULL DEFAULT 1,
          PRIMARY KEY(asset_id, message_id)
        ) WITHOUT ROWID
        """,
        "CREATE INDEX asset_link_msg ON asset_link(message_id)",

        // ---- background work, resumable ----
        """
        CREATE TABLE index_job(
          id INTEGER PRIMARY KEY,
          kind TEXT NOT NULL,              -- chunk | embed | extract_memory | summarize | photos | files | rebuild_ivf
          state TEXT NOT NULL DEFAULT 'pending',   -- pending | running | paused | done | failed
          cursor INTEGER NOT NULL DEFAULT 0,
          total INTEGER,
          priority INTEGER NOT NULL DEFAULT 5,
          attempts INTEGER NOT NULL DEFAULT 0,
          last_error TEXT,
          updated_at REAL NOT NULL,
          meta TEXT
        )
        """,
        "CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID",
    ]

    public static func migrate(_ db: SQLiteDatabase) throws {
        let v = Int(try db.scalarInt("PRAGMA user_version"))
        if v >= currentVersion { return }
        try db.transaction {
            if v < 1 { for s in v1 { try db.exec(s) } }
            try db.exec("PRAGMA user_version = \(currentVersion)")
        }
    }
}
