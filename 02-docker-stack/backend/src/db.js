'use strict';

const { Pool } = require('pg');
const config = require('./config');

const pool = new Pool(config.db);

// A pool-level error (for example Postgres being killed mid-connection) is
// emitted on idle clients. Without this handler Node treats it as an uncaught
// exception and the process exits, which would make the backend look crashed
// when the real fault is downstream.
pool.on('error', (error) => {
  log('warn', 'db.pool.error', { error: error.message });
});

function log(level, event, fields = {}) {
  process.stdout.write(
    JSON.stringify({ ts: new Date().toISOString(), level, event, ...fields }) + '\n',
  );
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Wait for Postgres to accept queries.
 *
 * The compose file already gates startup on a healthcheck, but this is kept as
 * a second line of defence: healthchecks make the common case reliable, they do
 * not make the process correct if it is started by hand or if the database is
 * restarted underneath a running backend.
 */
async function waitForDatabase({ attempts = 30, delayMs = 1000 } = {}) {
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      await pool.query('SELECT 1');
      log('info', 'db.ready', { attempt });
      return;
    } catch (error) {
      if (attempt === attempts) throw error;
      log('warn', 'db.waiting', { attempt, attempts, error: error.message });
      await sleep(delayMs);
    }
  }
}

/**
 * Idempotent schema creation and seed.
 *
 * Re-running must be a no-op: CREATE TABLE IF NOT EXISTS, and a seed guarded by
 * a NOT EXISTS check rather than a blind INSERT. The stack is brought up and
 * down repeatedly during the failure drills, so a migration that duplicated
 * rows on every start would corrupt the persistence evidence.
 */
async function migrate() {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    await client.query(`
      CREATE TABLE IF NOT EXISTS items (
        id          SERIAL PRIMARY KEY,
        name        TEXT        NOT NULL,
        description TEXT        NOT NULL DEFAULT '',
        created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
      )
    `);

    await client.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version    TEXT PRIMARY KEY,
        applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
      )
    `);

    const applied = await client.query(
      `INSERT INTO schema_migrations (version) VALUES ('001_items')
       ON CONFLICT (version) DO NOTHING
       RETURNING version`,
    );

    const seeds = [
      ['welcome', 'Seeded row proving the database is reachable through the proxy'],
      ['persistence-probe', 'This row must survive `docker compose down` and `up`'],
    ];

    let seeded = 0;
    for (const [name, description] of seeds) {
      const result = await client.query(
        `INSERT INTO items (name, description)
         SELECT $1, $2
         WHERE NOT EXISTS (SELECT 1 FROM items WHERE name = $1)
         RETURNING id`,
        [name, description],
      );
      seeded += result.rowCount;
    }

    await client.query('COMMIT');

    log('info', 'db.migrated', {
      migrationApplied: applied.rowCount > 0,
      rowsSeeded: seeded,
      idempotent: applied.rowCount === 0 && seeded === 0,
    });
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally {
    client.release();
  }
}

module.exports = { pool, migrate, waitForDatabase, log };
