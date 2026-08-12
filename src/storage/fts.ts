import type Database from "better-sqlite3";

export const FTS_SQL = `
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
  content,
  message_id UNINDEXED,
  channel_id UNINDEXED,
  author_id UNINDEXED,
  created_at UNINDEXED
);

DROP TRIGGER IF EXISTS messages_ai;
DROP TRIGGER IF EXISTS messages_au;
DROP TRIGGER IF EXISTS messages_ad;

CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
  INSERT INTO messages_fts(rowid, content, message_id, channel_id, author_id, created_at)
  VALUES (NEW.rowid, COALESCE(NEW.content, ''), NEW.id, NEW.channel_id, NEW.author_id, NEW.created_at);
END;

CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
  DELETE FROM messages_fts WHERE rowid = NEW.rowid;
  INSERT INTO messages_fts(rowid, content, message_id, channel_id, author_id, created_at)
  VALUES (NEW.rowid, COALESCE(NEW.content, ''), NEW.id, NEW.channel_id, NEW.author_id, NEW.created_at);
END;

CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
  DELETE FROM messages_fts WHERE rowid = OLD.rowid;
END;
`;

export const ensureFts = (db: Database.Database): void => {
  db.exec(FTS_SQL);

  const stats = db
    .prepare(
      `
      SELECT
        (SELECT COUNT(*) FROM messages) AS messages_count,
        (SELECT COUNT(*) FROM messages_fts) AS fts_count,
        (SELECT COUNT(*) FROM (
          SELECT message_id
          FROM messages_fts
          GROUP BY message_id
          HAVING COUNT(*) > 1
        )) AS duplicate_message_ids
    `,
    )
    .get() as {
    messages_count: number;
    fts_count: number;
    duplicate_message_ids: number;
  };

  const needsRebuild =
    stats.messages_count !== stats.fts_count || stats.duplicate_message_ids > 0;

  if (!needsRebuild) {
    return;
  }

  const rebuild = db.transaction(() => {
    db.prepare("DELETE FROM messages_fts").run();
    db.prepare(
      `
      INSERT INTO messages_fts(rowid, content, message_id, channel_id, author_id, created_at)
      SELECT rowid, COALESCE(content, ''), id, channel_id, author_id, created_at
      FROM messages
    `,
    ).run();
  });
  rebuild();
};
