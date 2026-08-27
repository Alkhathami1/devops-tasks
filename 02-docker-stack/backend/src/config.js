'use strict';

const fs = require('node:fs');

/**
 * Resolve the database password.
 *
 * Preference order is deliberate:
 *   1. POSTGRES_PASSWORD_FILE — a Docker secret mounted at /run/secrets/...
 *   2. POSTGRES_PASSWORD      — an environment variable
 *
 * The file form is preferred because environment variables are readable by
 * anyone who can run `docker inspect` on the container, are inherited by every
 * child process, and frequently end up in logs and crash dumps. The file form
 * keeps the value in a tmpfs mount readable only inside the container.
 * `scripts/drills/secrets-comparison.sh` demonstrates the difference.
 */
function readPassword() {
  const file = process.env.POSTGRES_PASSWORD_FILE;
  if (file) {
    try {
      return { value: fs.readFileSync(file, 'utf8').trim(), source: `file:${file}` };
    } catch (error) {
      throw new Error(`POSTGRES_PASSWORD_FILE is set to ${file} but could not be read: ${error.message}`);
    }
  }
  if (process.env.POSTGRES_PASSWORD) {
    return { value: process.env.POSTGRES_PASSWORD, source: 'env:POSTGRES_PASSWORD' };
  }
  throw new Error('No database password: set POSTGRES_PASSWORD_FILE (preferred) or POSTGRES_PASSWORD');
}

const password = readPassword();

module.exports = {
  port: Number(process.env.PORT || 3000),
  db: {
    host: process.env.POSTGRES_HOST || 'postgres',
    port: Number(process.env.POSTGRES_PORT || 5432),
    database: process.env.POSTGRES_DB || 'appdb',
    user: process.env.POSTGRES_USER || 'appuser',
    password: password.value,
    // Where the password came from. Logged; the value itself never is.
    passwordSource: password.source,
    max: Number(process.env.PG_POOL_MAX || 10),
    connectionTimeoutMillis: Number(process.env.PG_CONNECT_TIMEOUT_MS || 5000),
    idleTimeoutMillis: 30000,
  },
  // Deliberate test affordance for the RAM-exhaustion drill. Off unless asked.
  chaosEnabled: String(process.env.CHAOS_ENABLED || 'false').toLowerCase() === 'true',
};
