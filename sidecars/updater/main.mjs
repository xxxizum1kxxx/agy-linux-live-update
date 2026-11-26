import { execFile, spawn } from 'node:child_process';
import {
  closeSync,
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  readSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { homedir, tmpdir } from 'node:os';
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

// Plugin self-updates are intentionally excluded: they only surface as a
// badge in the panel footer, never in desktop notifications.
function hasUpdates(status) {
  const app = status?.app || {};
  const cli = status?.cli || {};
  return Boolean(app.updateAvailable || (cli.tracked && cli.updateAvailable));
}

function updateFingerprint(status) {
  const app = status?.app || {};
  const cli = status?.cli || {};
  const parts = [];
  if (app.updateAvailable) {
    parts.push(`app:${app.remoteBuildId || app.remoteVersion || '1'}`);
  }
  if (cli.tracked && cli.updateAvailable) {
    parts.push(`cli:${cli.remoteVersion || '1'}`);
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

  if (upToDate) {
    lines.push(
      `App: ${app.localVersion || '?'} (${app.localBuildId || 'ok'})`
    );
    if (cli.tracked) {
      lines.push(`CLI (agy): ${cli.localVersion || '?'}`);
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

function readText(path) {
  try {
    return readFileSync(path, 'utf8').trim();
  } catch {
    return '';
  }
}

function execFileOutput(file, args, timeoutMs = 3000) {
  return new Promise((resolve) => {
    execFile(
      file,
      args,
      { timeout: timeoutMs, env: process.env, encoding: 'utf8' },
      (err, stdout) => {
        if (err) {
          resolve(null);
          return;
        }
        const first = String(stdout || '').split(/\r?\n/)[0].trim();
        resolve(first || null);
      }
    );
  });
}

// Mirrors installed_app_version() in scripts/common.sh without spawning Python.
function readAppVersionFromAsar(asarPath = '/opt/antigravity/resources/app.asar') {
  let fd;
  try {
    fd = openSync(asarPath, 'r');
    const prefix = Buffer.alloc(16);
    if (readSync(fd, prefix, 0, 16, 0) < 16) return null;
    const headerPickleSize = prefix.readUInt32LE(4);
    const jsonSize = prefix.readUInt32LE(12);
    if (!jsonSize || jsonSize > 16 * 1024 * 1024) return null;
    const headerBuf = Buffer.alloc(jsonSize);
    if (readSync(fd, headerBuf, 0, jsonSize, 16) < jsonSize) return null;
    const header = JSON.parse(headerBuf.toString('utf8'));
    const meta = header?.files?.['package.json'];
    if (!meta || typeof meta !== 'object' || typeof meta.size !== 'number') {
      return null;
    }
    let raw;
    if (meta.unpacked) {
      const unpackedPath = join(`${asarPath}.unpacked`, 'package.json');
      if (!existsSync(unpackedPath)) return null;
      raw = readFileSync(unpackedPath, 'utf8');
    } else {
      const offset = 8 + headerPickleSize + Number(meta.offset);
      const pkgBuf = Buffer.alloc(meta.size);
      if (readSync(fd, pkgBuf, 0, meta.size, offset) < meta.size) return null;
      raw = pkgBuf.toString('utf8');
    }
    return JSON.parse(raw)?.version || null;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) {
      try {
        closeSync(fd);
      } catch {
        /* ignore */
      }
    }
  }
}

function readLocalAppInfo() {
  const localBuildId = readText('/opt/antigravity/.build-id') || null;
  const localVersion =
    readAppVersionFromAsar() ||
    (localBuildId ? localBuildId.split('-')[0] || null : null);
  return { localVersion, localBuildId };
}

async function readLocalPluginInfo() {
  let localVersion = null;
  try {
    const manifest = JSON.parse(
      readFileSync(join(PLUGIN_ROOT, 'plugin.json'), 'utf8')
    );
    localVersion = manifest?.version || null;
  } catch {
    localVersion = null;
  }
  let localCommit = null;
  if (existsSync(join(PLUGIN_ROOT, '.git'))) {
    localCommit = await execFileOutput(
      'git',
      ['-C', PLUGIN_ROOT, 'rev-parse', '--short', 'HEAD'],
      2000
    );
  }
  return { localVersion, localCommit };
}

async function readLocalCliVersion() {
  const direct = await execFileOutput('agy', ['--version'], 3000);
  if (direct) return direct;
  const fallback = join(homedir(), '.local', 'bin', 'agy');
  if (existsSync(fallback)) {
    return execFileOutput(fallback, ['--version'], 3000);
  }
  return null;
}

async function readLiveLocalInfo() {
  const app = readLocalAppInfo();
  const [plugin, cliVersion] = await Promise.all([
    readLocalPluginInfo(),
    readLocalCliVersion(),
  ]);
  return {
    app,
    cli: { localVersion: cliVersion },
    plugin,
  };
}

function compareSemver(a, b) {
  if (!a || !b) return 0;
  const pa = String(a)
    .split('.')
    .slice(0, 3)
    .map((x) => Number.parseInt(x, 10));
  const pb = String(b)
    .split('.')
    .slice(0, 3)
    .map((x) => Number.parseInt(x, 10));
  if (pa.some(Number.isNaN) || pb.some(Number.isNaN)) return 0;
  for (let i = 0; i < 3; i++) {
    const diff = (pa[i] || 0) - (pb[i] || 0);
    if (diff !== 0) return diff;
  }
  return 0;
}

// Overlay live on-disk local versions onto a cached status and recompute
// update flags so restarts after App/Plugin updates never flash stale versions.
function overlayLiveLocal(cachedStatus, local) {
  if (!cachedStatus || !local) return cachedStatus;
  const app = { ...(cachedStatus.app || {}) };
  const cli = { ...(cachedStatus.cli || {}) };
  const plugin = { ...(cachedStatus.plugin || {}) };

  app.localVersion = local.app.localVersion;
  app.localBuildId = local.app.localBuildId;
  if (!app.remoteBuildId) {
    app.updateAvailable = false;
  } else if (app.localBuildId === app.remoteBuildId) {
    app.updateAvailable = false;
  } else if (
    app.localVersion &&
    app.remoteVersion &&
    compareSemver(app.localVersion, app.remoteVersion) > 0
  ) {
    app.updateAvailable = false;
  } else {
    app.updateAvailable = true;
  }

  cli.localVersion = local.cli.localVersion;
  cli.tracked = Boolean(cli.localVersion);
  if (!cli.tracked) {
    cli.remoteVersion = null;
    cli.updateAvailable = false;
  } else {
    cli.updateAvailable = Boolean(
      cli.remoteVersion &&
        compareSemver(cli.remoteVersion, cli.localVersion) > 0
    );
  }

  plugin.localVersion = local.plugin.localVersion;
  plugin.localCommit = local.plugin.localCommit;
  if (plugin.remoteVersion && plugin.localVersion) {
    const cmp = compareSemver(plugin.remoteVersion, plugin.localVersion);
    plugin.updateAvailable = cmp > 0;
    plugin.localAhead = cmp < 0;
  } else {
    plugin.updateAvailable = Boolean(
      plugin.remoteVersion && !plugin.localVersion
    );
    plugin.localAhead = false;
  }

  return { ...cachedStatus, app, cli, plugin };
}

let inFlightRefresh = null;

async function doRefreshAndMaybeNotify({ notify = false } = {}) {
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
    const fallbackStatus = previous?.status
      ? overlayLiveLocal(previous.status, await readLiveLocalInfo())
      : undefined;
    return {
      ...result,
      status: fallbackStatus,
      stale: Boolean(fallbackStatus),
      settings: readSettings(),
    };
  }

  let nextNotified = previous?.notifiedFingerprint || '';
  if (notify) {
    nextNotified = await maybeSendStatusNotify(result.status, previous);
  }

  const latestCache = readCache();
  const payload = {
    checkedAt: result.checkedAt,
    ok: true,
    status: result.status,
    log: result.log,
    notifiedFingerprint: nextNotified,
    lastJob: latestCache?.lastJob || previous?.lastJob || null,
  };
  writeCache(payload);
  return {
    ...result,
    notifiedFingerprint: nextNotified,
    settings: readSettings(),
  };
}

// Coalesce concurrent startup + panel refreshes so we do not spawn duplicate
// status-json probes right after a restart.
async function refreshAndMaybeNotify({ notify = false } = {}) {
  if (inFlightRefresh) {
    const res = await inFlightRefresh;
    return { ...res, settings: readSettings() };
  }
  const p = doRefreshAndMaybeNotify({ notify });
  inFlightRefresh = p;
  try {
    return await p;
  } finally {
    if (inFlightRefresh === p) inFlightRefresh = null;
  }
}

async function cachedStatusResponse() {
  recoverDetachedJobs();
  const cache = readCache();
  if (!cache?.status) return null;
  const liveStatus = overlayLiveLocal(cache.status, await readLiveLocalInfo());
  return {
    ok: true,
    status: liveStatus,
    log: cache.log || '',
    cached: true,
    checkedAt: cache.checkedAt || null,
    stale: true,
    lastError: cache.lastError || null,
    lastJob: cache.lastJob || null,
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
    const cached = await cachedStatusResponse();
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

// Run an update job and remember its output so the panel log survives reloads.
function recordJob(kind, response, at = new Date().toISOString()) {
  try {
    writeCache({
      ...(readCache() || {}),
      lastJob: { kind, ...response, at },
    });
  } catch (err) {
    console.warn('[linux-updater] failed to persist job log:', err);
  }
}

async function runUpdateJob(kind, args, timeoutMs) {
  const result = await runCore(args, { timeoutMs });
  const response = {
    ok: result.code === 0,
    code: result.code,
    log: (result.stdout + '\n' + result.stderr).trim(),
  };
  recordJob(kind, response);
  return response;
}

/*
 * Detached update helpers for App and Plugin updates:
 *   - Plugin self-update replaces this plugin's own directory and triggers a
 *     Sidecar restart; it runs from a temp copy of scripts/.
 *   - App update quits Antigravity (stopping this Sidecar) before pkexec runs,
 *     then automatically relaunches Antigravity as the regular user on success.
 * Both write their output and exit code to dataDir() so the next Sidecar start
 * records them into Activity log (lastJob).
 */
function detachedJobPaths(kind) {
  const dir = ensureDataDir();
  return {
    log: join(dir, `${kind}-update.log`),
    exit: join(dir, `${kind}-update.exit`),
  };
}

function recoverDetachedJobs() {
  const pending = [];
  for (const kind of ['app', 'plugin']) {
    const { log, exit } = detachedJobPaths(kind);
    if (!existsSync(exit)) continue;
    try {
      const mtimeMs = statSync(exit).mtimeMs;
      pending.push({ kind, log, exit, mtimeMs });
    } catch {
      /* ignore */
    }
  }
  pending.sort((a, b) => a.mtimeMs - b.mtimeMs);
  for (const item of pending) {
    const code = Number(readText(item.exit));
    const at = new Date(item.mtimeMs).toISOString();
    recordJob(item.kind, { ok: code === 0, code, log: readText(item.log) }, at);
    rmSync(item.exit, { force: true });
  }
}

function runAppUpdateDetached() {
  return new Promise((resolve) => {
    const { log, exit } = detachedJobPaths('app');
    rmSync(exit, { force: true });
    // Keep the command line free of "/opt/antigravity/antigravity" so
    // install_app_from_tarball's `pkill -f` never kills this wrapper.
    const launcher = '/usr/local/bin/antigravity';
    const script = [
      'bash "$1" update-app --yes >"$2" 2>&1; code=$?',
      'echo "$code" >"$3"',
      'if [ "$code" -eq 0 ] && [ -x "$4" ] && grep -q "^App updated\\." "$2"; then',
      '  echo "Relaunching Antigravity..." >>"$2"',
      '  (',
      '    unset ELECTRON_RUN_AS_NODE ANTIGRAVITY_LS_ADDRESS ANTIGRAVITY_CSRF_TOKEN \\',
      '      ANTIGRAVITY_SIDECAR_WEB_PORT ANTIGRAVITY_SIDECAR_UI_TOKEN \\',
      '      ANTIGRAVITY_EXECUTABLE_DATA_DIR ANTIGRAVITY_AGENTAPI_EXE',
      '    if command -v setsid >/dev/null 2>&1; then',
      '      setsid -f "$4" </dev/null >/dev/null 2>&1',
      '    else',
      '      nohup "$4" </dev/null >/dev/null 2>&1 &',
      '    fi',
      '  )',
      'fi',
      'exit "$code"',
    ].join('\n');
    const child = spawn(
      'bash',
      ['-c', script, 'bash', CORE, log, exit, launcher],
      { detached: true, stdio: 'ignore', env: process.env }
    );
    child.on('error', (err) => resolve({ ok: false, code: 1, log: String(err) }));
    child.on('close', (code) => {
      rmSync(exit, { force: true });
      resolve({ ok: code === 0, code: code ?? 1, log: readText(log) });
    });
  });
}

function runPluginUpdateDetached() {
  return new Promise((resolve) => {
    const { log, exit } = detachedJobPaths('plugin');
    rmSync(exit, { force: true });
    let runner;
    try {
      runner = mkdtempSync(join(tmpdir(), 'linux-updater-'));
      cpSync(join(PLUGIN_ROOT, 'scripts'), join(runner, 'scripts'), { recursive: true });
      cpSync(join(PLUGIN_ROOT, 'plugin.json'), join(runner, 'plugin.json'));
    } catch (err) {
      resolve({ ok: false, code: 1, log: `Failed to stage updater: ${err}` });
      return;
    }
    const script =
      'bash "$1" update-plugin --yes >"$2" 2>&1; code=$?; ' +
      'echo "$code" >"$3"; rm -rf "$4"; exit "$code"';
    const child = spawn(
      'bash',
      ['-c', script, 'bash', join(runner, 'scripts', 'update-core.sh'), log, exit, runner],
      { detached: true, stdio: 'ignore', env: process.env }
    );
    child.on('error', (err) => resolve({ ok: false, code: 1, log: String(err) }));
    child.on('close', (code) => {
      // Still alive: report directly and consume the exit marker.
      rmSync(exit, { force: true });
      resolve({ ok: code === 0, code: code ?? 1, log: readText(log) });
    });
  });
}

app.api('/api/update-app', async () => {
  const response = await runAppUpdateDetached();
  recordJob('app', response);
  return response;
});

app.api('/api/update-cli', async () =>
  runUpdateJob('cli', ['update-cli', '--yes'], 300_000)
);

app.api('/api/update-plugin', async () => {
  const response = await runPluginUpdateDetached();
  recordJob('plugin', response);
  return response;
});

// Recover App / Plugin updates that outlived the previous Sidecar process.
recoverDetachedJobs();

await app.run();

refreshAndMaybeNotify({ notify: true }).catch((err) => {
  console.warn('[linux-updater] startup check failed:', err);
});
