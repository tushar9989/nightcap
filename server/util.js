import { createHash } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

export const ROOT = path.resolve(import.meta.dirname, '..');
export const DATA_DIR = path.resolve(process.env.DATA_DIR || path.join(ROOT, 'data'));

export const hashId = (s, n = 12) => createHash('sha1').update(s).digest('hex').slice(0, n);

const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });
export const naturalCompare = (a, b) => collator.compare(a, b);

// Changes whenever the file on disk changes; keys every cache.
export const fileSig = (f) => `${f.size}:${f.mtime}`;
export const sigHash = (f) => hashId(`${f.path}|${fileSig(f)}`, 10);

export function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

function findTool(name, envVar) {
  const candidates = [process.env[envVar], name, `/opt/homebrew/bin/${name}`, `/usr/local/bin/${name}`].filter(Boolean);
  for (const c of candidates) {
    try {
      const r = spawnSync(c, ['-version'], { stdio: 'ignore', timeout: 5000 });
      if (r.status === 0) return c;
    } catch {}
  }
  return null;
}

export const FFMPEG = findTool('ffmpeg', 'FFMPEG');
export const FFPROBE = findTool('ffprobe', 'FFPROBE');

// Runs a command and resolves with { code, stdout (Buffer), stderr (string) }.
export function run(cmd, args, { timeout = 0, onSpawn } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    onSpawn?.(child);
    const out = [];
    let err = '';
    let timer;
    if (timeout) timer = setTimeout(() => child.kill('SIGKILL'), timeout);
    child.stdout.on('data', (d) => out.push(d));
    child.stderr.on('data', (d) => {
      err += d;
      if (err.length > 1e6) err = err.slice(-5e5);
    });
    child.on('error', reject);
    child.on('close', (code) => {
      clearTimeout(timer);
      resolve({ code, stdout: Buffer.concat(out), stderr: err });
    });
  });
}

// Limits how many async jobs of one kind run at once.
export class Limiter {
  constructor(max) {
    this.max = max;
    this.active = 0;
    this.waiting = [];
  }
  async run(fn) {
    if (this.active >= this.max) await new Promise((r) => this.waiting.push(r));
    this.active++;
    try {
      return await fn();
    } finally {
      this.active--;
      this.waiting.shift()?.();
    }
  }
}

// A JSON file kept in memory and written back (atomically) shortly after changes.
export class JsonStore {
  constructor(file, defaults) {
    this.file = file;
    this.timer = null;
    try {
      this.data = { ...structuredClone(defaults), ...JSON.parse(fs.readFileSync(file, 'utf8')) };
    } catch {
      this.data = structuredClone(defaults);
    }
  }
  save() {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.flush(), 400);
  }
  flush() {
    clearTimeout(this.timer);
    this.timer = null;
    ensureDir(path.dirname(this.file));
    const tmp = `${this.file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(this.data));
    fs.renameSync(tmp, this.file);
  }
}
