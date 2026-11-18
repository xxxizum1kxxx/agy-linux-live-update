import { spawn } from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SidecarApp } from 'sidecar_sdk';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PLUGIN_ROOT = join(__dirname, '..', '..');
const CORE = join(PLUGIN_ROOT, 'scripts', 'update-core.sh');
const DEFAULT_SETTINGS = {
  // false = notify only when updates are available (deduped by fingerprint)
  // true  = notify on every background check with current status
  notifyEveryStartup: false,
};

function dataDir() {
  const fromEnv = process.env.ANTIGRAVITY_EXECUTABLE_DATA_DIR;
  if (fromEnv) return fromEnv;
  return join(
    process.env.XDG_CACHE_HOME || join(homedir(), '.cache'),
    'antigravity',
    'linux-updater'
  );
}

function cachePath() {
  return join(dataDir(), 'status-cache.json');
}

function settingsPath() {
  return join(dataDir(), 'settings.json');
}

function ensureDataDir() {
  const dir = dataDir();
  mkdirSync(dir, { recursive: true });
  return dir;
}

function readCache() {
  try {
    const raw = readFileSync(cachePath(), 'utf8');
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function writeCache(payload) {
  ensureDataDir();
  writeFileSync(cachePath(), JSON.stringify(payload, null, 2) + '\n');
}

function readSettings() {
  try {
    const raw = readFileSync(settingsPath(), 'utf8');
    const parsed = JSON.parse(raw);
    return {
      ...DEFAULT_SETTINGS,
      notifyEveryStartup: Boolean(parsed.notifyEveryStartup),
    };
  } catch {
    return { ...DEFAULT_SETTINGS };
  }
}

function writeSettings(settings) {
  ensureDataDir();
  const next = {
    ...DEFAULT_SETTINGS,
    notifyEveryStartup: Boolean(settings.notifyEveryStartup),
  };
  writeFileSync(settingsPath(), JSON.stringify(next, null, 2) + '\n');
  return next;
}

function hasUpdates(status) {
  const app = status?.app || {};
  const cli = status?.cli || {};
  const plugin = status?.plugin || {};
  return Boolean(
    app.updateAvailable ||
      (cli.tracked && cli.updateAvailable) ||
      plugin.updateAvailable
  );
}

function updateFingerprint(status) {
  const app = status?.app || {};
  const cli = status?.cli || {};
  const plugin = status?.plugin || {};
  const parts = [];
  if (app.updateAvailable) {
    parts.push(`app:${app.remoteBuildId || app.remoteVersion || '1'}`);
  }
  if (cli.tracked && cli.updateAvailable) {
    parts.push(`cli:${cli.remoteVersion || '1'}`);
  }
  if (plugin.updateAvailable) {
    parts.push(
      `plugin:${plugin.remoteVersion || '1'}:${plugin.remoteCommit || ''}`
    );
  }
  return parts.join('|') || '';
}

function resolveNotifyIcon() {
  // notify-send often ignores SVG; prefer installed Antigravity PNGs.
  const candidates = [
    '/usr/local/share/icons/hicolor/128x128/apps/antigravity.png',
    '/usr/local/share/icons/hicolor/64x64/apps/antigravity.png',
    '/usr/local/share/icons/hicolor/48x48/apps/antigravity.png',
    '/opt/antigravity/antigravity.png',
  ];
  for (const path of candidates) {
    if (existsSync(path)) return path;
  }
  // Theme icon name as last resort before a generic update glyph.
  return 'antigravity';
}

function notifyBody(status, { upToDate = false } = {}) {
  const lines = [];
  const app = status?.app || {};
  const cli = status?.cli || {};

  const plugin = status?.plugin || {};

  if (upToDate) {
    lines.push(
      `App: ${app.localVersion || '?'} (${app.localBuildId || 'ok'})`
    );
    if (cli.tracked) {
      lines.push(`CLI (agy): ${cli.localVersion || '?'}`);
    }
    if (plugin.localVersion) {
      lines.push(`Plugin: ${plugin.localVersion}`);
    }
    return lines.join('\n');
  }

  if (app.updateAvailable) {
    lines.push(
      `App: ${app.localVersion || '?'} → ${app.remoteVersion || '?'}`
    );
  }
  if (cli.tracked && cli.updateAvailable) {
    lines.push(
      `CLI (agy): ${cli.localVersion || 'not installed'} → ${cli.remoteVersion || '?'}`
    );
  }
  if (plugin.updateAvailable) {
    lines.push(
      `Plugin: ${plugin.localVersion || '?'} → ${plugin.remoteVersion || '?'}`
    );
  }
  lines.push('Open Antigravity → Extensions → Linux Updater.');
  return lines.join('\n');
}

function sendNotify(title, body) {
  return new Promise((resolve) => {
    const args = [
      '--app-name=Antigravity Linux Updater',
      `--icon=${resolveNotifyIcon()}`,
      '--urgency=normal',
      '--category=device',
    ];
    args.push(title, body);

    const child = spawn('notify-send', args, {
      stdio: ['ignore', 'ignore', 'pipe'],
      env: process.env,
    });
    let stderr = '';
    child.stderr?.on('data', (chunk) => {
      stderr += chunk.toString();
    });
    child.on('error', (err) => {
      console.warn('[linux-updater] notify-send unavailable:', err.message);
      resolve(false);
    });
    child.on('close', (code) => {
      if (code !== 0) {
        console.warn(
          '[linux-updater] notify-send failed:',
          stderr.trim() || `exit ${code}`
        );
        resolve(false);
      } else {
        resolve(true);
      }
    });
  });
}

function runCore(args, { timeoutMs = 600_000 } = {}) {
  return new Promise((resolve) => {
    const child = spawn(CORE, args, {
      cwd: dirname(CORE),
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => {
      child.kill('SIGTERM');
      resolve({
        ok: false,
        code: -1,
        stdout,
        stderr: stderr + '\nTimed out',
      });
    }, timeoutMs);
    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      resolve({ ok: code === 0 || code === 100, code: code ?? 1, stdout, stderr });
    });
    child.on('error', (err) => {
      clearTimeout(timer);
      resolve({ ok: false, code: 1, stdout, stderr: String(err) });
    });
  });
}

async function fetchFreshStatus() {
  const result = await runCore(['status-json'], { timeoutMs: 120_000 });
  if (!result.ok && result.code !== 0) {
    return {
      ok: false,
      error: result.stderr || result.stdout || 'status failed',
      code: result.code,
      log: (result.stdout + result.stderr).trim(),
      cached: false,
    };
  }
  try {
    const status = JSON.parse(result.stdout);
    return {
      ok: true,
      status,
      log: result.stderr.trim(),
      cached: false,
      checkedAt: new Date().toISOString(),
    };
  } catch (err) {
    return {
      ok: false,
      error: `Failed to parse status JSON: ${err}`,
      log: (result.stdout + '\n' + result.stderr).trim(),
      cached: false,
    };
  }
}

async function maybeSendStatusNotify(status, previous) {
  const settings = readSettings();
  const fingerprint = updateFingerprint(status);
  const notifiedFingerprint = previous?.notifiedFingerprint || '';
  let nextNotified = notifiedFingerprint;

  if (settings.notifyEveryStartup) {
    const updates = hasUpdates(status);
    const title = updates
      ? 'Antigravity update available'
      : 'Antigravity is up to date';
    const body = notifyBody(status, { upToDate: !updates });
    const sent = await sendNotify(title, body);
    if (sent) nextNotified = fingerprint || 'uptodate';
    return nextNotified;
  }

  if (fingerprint && fingerprint !== notifiedFingerprint) {
    const sent = await sendNotify(
      'Antigravity update available',
      notifyBody(status, { upToDate: false })
    );
    if (sent) nextNotified = fingerprint;
  }

  if (!fingerprint) nextNotified = '';
  return nextNotified;
}

async function refreshAndMaybeNotify({ notify = false } = {}) {
  const previous = readCache();
  const result = await fetchFreshStatus();
  if (!result.ok) {
    if (!previous?.status) {
      writeCache({
        checkedAt: new Date().toISOString(),
        ok: false,
        error: result.error,
        log: result.log,
        notifiedFingerprint: previous?.notifiedFingerprint || '',
      });
    } else {
      writeCache({
        ...previous,
        lastError: result.error,
        lastErrorAt: new Date().toISOString(),
        lastErrorLog: result.log,
      });
    }
    return { ...result, status: previous?.status, stale: Boolean(previous?.status) };
  }

  let nextNotified = previous?.notifiedFingerprint || '';
  if (notify) {
    nextNotified = await maybeSendStatusNotify(result.status, previous);
  }

  const payload = {
    checkedAt: result.checkedAt,
    ok: true,
    status: result.status,
    log: result.log,
    notifiedFingerprint: nextNotified,
  };
  writeCache(payload);
  return {
    ...result,
    notifiedFingerprint: nextNotified,
    settings: readSettings(),
  };
}

function cachedStatusResponse() {
  const cache = readCache();
  if (!cache?.status) return null;
  return {
    ok: true,
    status: cache.status,
    log: cache.log || '',
    cached: true,
    checkedAt: cache.checkedAt || null,
    stale: true,
    lastError: cache.lastError || null,
    settings: readSettings(),
  };
}

async function handleStatus(data = {}, { forceFresh = false } = {}) {
  const wantFresh =
    forceFresh ||
    data.fresh === true ||
    data.fresh === '1' ||
    data.fresh === 1;

  if (!wantFresh) {
    const cached = cachedStatusResponse();
    if (cached) return cached;
    return {
      ok: false,
      cached: false,
      pending: true,
      error: 'No cached status yet',
      settings: readSettings(),
    };
  }

  // Panel / manual refresh never pops notify-send.
  const result = await refreshAndMaybeNotify({ notify: false });
  return { ...result, settings: readSettings() };
}

const app = new SidecarApp();

app.page('/', () =>
  readFileSync(new URL('./index.html', import.meta.url), 'utf8')
);

app.api('/api/status', async (data) => handleStatus(data, { forceFresh: false }), 'GET');
app.api('/api/status', async (data) => handleStatus(data, { forceFresh: true }), 'POST');

app.api('/api/settings', async () => ({ ok: true, settings: readSettings() }), 'GET');
app.api('/api/settings', async (data = {}) => {
  const next = writeSettings({
    notifyEveryStartup: Boolean(data.notifyEveryStartup),
  });
  return { ok: true, settings: next };
}, 'POST');

app.api('/api/update-app', async () => {
  const result = await runCore(['update-app', '--yes'], { timeoutMs: 900_000 });
  return {
    ok: result.code === 0,
    code: result.code,
    log: (result.stdout + '\n' + result.stderr).trim(),
  };
});

app.api('/api/update-cli', async () => {
  const result = await runCore(['update-cli', '--yes'], { timeoutMs: 300_000 });
  return {
    ok: result.code === 0,
    code: result.code,
    log: (result.stdout + '\n' + result.stderr).trim(),
  };
});

app.api('/api/update-plugin', async () => {
  const result = await runCore(['update-plugin', '--yes'], { timeoutMs: 300_000 });
  return {
    ok: result.code === 0,
    code: result.code,
    log: (result.stdout + '\n' + result.stderr).trim(),
  };
});

await app.run();

refreshAndMaybeNotify({ notify: true }).catch((err) => {
  console.warn('[linux-updater] startup check failed:', err);
});
