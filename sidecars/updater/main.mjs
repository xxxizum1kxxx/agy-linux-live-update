import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SidecarApp } from 'sidecar_sdk';

const __dirname = dirname(fileURLToPath(import.meta.url));
const CORE = join(__dirname, '..', '..', 'scripts', 'update-core.sh');

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

const app = new SidecarApp();

app.page('/', () =>
  readFileSync(new URL('./index.html', import.meta.url), 'utf8')
);

app.api('/api/status', async () => {
  const result = await runCore(['status-json'], { timeoutMs: 120_000 });
  if (!result.ok && result.code !== 0) {
    return {
      ok: false,
      error: result.stderr || result.stdout || 'status failed',
      code: result.code,
      log: (result.stdout + result.stderr).trim(),
    };
  }
  try {
    const status = JSON.parse(result.stdout);
    return { ok: true, status, log: result.stderr.trim() };
  } catch (err) {
    return {
      ok: false,
      error: `Failed to parse status JSON: ${err}`,
      log: (result.stdout + '\n' + result.stderr).trim(),
    };
  }
});

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

app.run();
