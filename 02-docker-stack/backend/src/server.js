'use strict';

const express = require('express');
const config = require('./config');
const { pool, migrate, waitForDatabase, log } = require('./db');

const app = express();
app.use(express.json({ limit: '64kb' }));

const startedAt = Date.now();

/**
 * Upper bound on how long the health check may spend probing the database.
 *
 * This must be comfortably below nginx's proxy_read_timeout for /api-health
 * (5s). Without it the probe inherits the pool's connectionTimeoutMillis of
 * 5000ms, so when Postgres is down /health takes ~5s to fail and races nginx's
 * own timeout: the caller then sometimes gets the backend's honest JSON 503 and
 * sometimes nginx's 504 HTML page, depending on which side loses by a few
 * milliseconds. A health endpoint has to answer fast and deterministically,
 * especially when the news is bad.
 */
const HEALTH_PROBE_TIMEOUT_MS = Number(process.env.HEALTH_PROBE_TIMEOUT_MS || 2000);

/** Resolve with the query result, or reject quickly if the database is slow. */
function probeDatabase(timeoutMs = HEALTH_PROBE_TIMEOUT_MS) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const timer = setTimeout(() => {
      settled = true;
      reject(new Error(`database probe exceeded ${timeoutMs}ms`));
    }, timeoutMs);

    pool
      .query('SELECT 1 AS ok')
      .then((result) => {
        if (settled) return;
        clearTimeout(timer);
        resolve(result);
      })
      .catch((error) => {
        if (settled) return; // the timeout already rejected; do not double-settle
        clearTimeout(timer);
        reject(error);
      });
  });
}

/**
 * Liveness + readiness in one endpoint.
 *
 * This reports the database honestly. A health endpoint that returns 200 while
 * its only datastore is unreachable is worse than no health endpoint at all: it
 * tells the orchestrator to keep sending traffic to a backend that cannot serve
 * it, and it makes the "DB killed" failure drill unfalsifiable. When Postgres is
 * down this returns 503 and says so.
 */
app.get('/health', async (req, res) => {
  const base = {
    service: 'backend',
    uptimeSeconds: Math.round((Date.now() - startedAt) / 1000),
    pid: process.pid,
  };

  try {
    const result = await probeDatabase();
    res.status(200).json({
      status: 'ok',
      database: { reachable: true, check: result.rows[0].ok === 1 },
      ...base,
    });
  } catch (error) {
    res.status(503).json({
      status: 'degraded',
      database: { reachable: false, error: error.message },
      ...base,
    });
  }
});

app.get('/api/items', async (req, res) => {
  try {
    const result = await pool.query(
      'SELECT id, name, description, created_at FROM items ORDER BY id ASC',
    );
    res.json({ count: result.rowCount, items: result.rows });
  } catch (error) {
    log('error', 'items.list.failed', { error: error.message });
    res.status(503).json({ error: 'database unavailable', detail: error.message });
  }
});

app.post('/api/items', async (req, res) => {
  const { name, description } = req.body || {};

  if (typeof name !== 'string' || name.trim() === '') {
    return res.status(400).json({ error: 'name is required and must be a non-empty string' });
  }

  try {
    const result = await pool.query(
      `INSERT INTO items (name, description)
       VALUES ($1, $2)
       RETURNING id, name, description, created_at`,
      [name.trim(), typeof description === 'string' ? description : ''],
    );
    log('info', 'items.created', { id: result.rows[0].id, name: result.rows[0].name });
    res.status(201).json(result.rows[0]);
  } catch (error) {
    log('error', 'items.create.failed', { error: error.message });
    res.status(503).json({ error: 'database unavailable', detail: error.message });
  }
});

/**
 * RAM-exhaustion drill support.
 *
 * Disabled unless CHAOS_ENABLED=true. It is NOT reachable from the host: nginx
 * proxies only /api, so /internal/* has no route in from outside the Docker
 * networks. `scripts/drills/03-oom-kill.sh` triggers it from inside.
 *
 * The allocation deliberately happens in THIS process, which is PID 1 in the
 * container. If the allocation were done by a child process (say a `docker exec`
 * of some memory hog), the kernel OOM killer would reap the child and leave PID 1
 * alive; the container would survive and `docker inspect` would report
 * OOMKilled: false, proving nothing about the container's memory limit.
 *
 * Buffers are used rather than plain JS arrays because Buffer memory is
 * allocated outside the V8 heap and so is not capped by --max-old-space-size.
 * Each buffer is filled, because untouched pages may never be faulted in and
 * therefore never counted against the cgroup limit.
 */
if (config.chaosEnabled) {
  app.post('/internal/chaos/oom', (req, res) => {
    if (req.query.confirm !== 'yes') {
      return res.status(400).json({ error: 'refusing without ?confirm=yes' });
    }

    log('warn', 'chaos.oom.starting', { pid: process.pid, note: 'allocating in PID 1 until the cgroup kills us' });
    res.status(202).json({ status: 'allocating', pid: process.pid });

    const hog = [];
    const CHUNK = 16 * 1024 * 1024; // 16 MiB per step

    const allocate = () => {
      try {
        const buffer = Buffer.allocUnsafe(CHUNK);
        buffer.fill(0x5a); // touch every page so it is charged to the cgroup
        hog.push(buffer);
        log('warn', 'chaos.oom.allocated', {
          chunks: hog.length,
          totalMiB: (hog.length * CHUNK) / (1024 * 1024),
          rssMiB: Math.round(process.memoryUsage().rss / (1024 * 1024)),
        });
        setImmediate(allocate);
      } catch (error) {
        log('error', 'chaos.oom.allocation-failed', { error: error.message });
      }
    };

    setImmediate(allocate);
  });

  /**
   * Abrupt process death, for the crash-recovery drill.
   *
   * This exists because neither obvious alternative actually simulates a crash:
   *
   *   - `docker kill` marks the container as manually stopped, so `unless-stopped`
   *     deliberately declines to restart it. That is the policy working as
   *     designed (an operator asked for it to stop), not a crash.
   *   - `kill -9 1` from inside the container is silently discarded: the kernel
   *     does not deliver uncatchable signals to PID 1 from within its own PID
   *     namespace. The container does not even die.
   *
   * A real crash is PID 1 exiting on its own, which is what this does. The
   * restart policy then treats it as an unexpected failure and restarts it.
   */
  app.post('/internal/chaos/crash', (req, res) => {
    if (req.query.confirm !== 'yes') {
      return res.status(400).json({ error: 'refusing without ?confirm=yes' });
    }
    const code = Number(req.query.code || 1);
    log('warn', 'chaos.crash', { pid: process.pid, exitCode: code });
    res.status(202).json({ status: 'crashing', pid: process.pid, exitCode: code });
    // Let the response flush before dying.
    setTimeout(() => process.exit(code), 50);
  });

  log('warn', 'chaos.enabled', {
    note: 'CHAOS_ENABLED=true - /internal/chaos/{oom,crash} are live. Test affordance only.',
  });
}

app.use((req, res) => res.status(404).json({ error: 'not found', path: req.path }));

async function start() {
  log('info', 'backend.starting', {
    port: config.port,
    db: { host: config.db.host, port: config.db.port, database: config.db.database, user: config.db.user },
    passwordSource: config.db.passwordSource, // the SOURCE, never the value
    chaosEnabled: config.chaosEnabled,
  });

  await waitForDatabase();
  await migrate();

  const server = app.listen(config.port, '0.0.0.0', () => {
    log('info', 'backend.listening', { port: config.port, pid: process.pid });
  });

  // Compose sends SIGTERM on `stop`/`down`. Closing cleanly keeps the restart
  // drills measuring restart time rather than a 10 second kill timeout.
  const shutdown = (signal) => {
    log('info', 'backend.shutdown', { signal });
    server.close(() => {
      pool.end().finally(() => process.exit(0));
    });
    setTimeout(() => process.exit(0), 5000).unref();
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

start().catch((error) => {
  log('error', 'backend.start.failed', { error: error.message });
  process.exit(1);
});
