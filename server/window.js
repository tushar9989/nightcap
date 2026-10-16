// Opens Marquee in its own app-style window (no tabs or address bar).
// Chrome is preferred: it plays the on-the-fly converted streams that
// Safari cannot. Usable on its own: node server/window.js [url]
//
// The browser runs with its own profile, so it is a separate instance from
// the user's everyday browser. With `own`, it is started as a child of the
// server, which ends it on shutdown.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { DATA_DIR } from './util.js';

const CHROMIUM_APPS = ['Google Chrome', 'Microsoft Edge', 'Brave Browser', 'Chromium'];

export function openWindow(url, { own = false } = {}) {
  if (process.platform !== 'darwin') {
    const opener = process.platform === 'win32' ? 'start' : 'xdg-open';
    spawn(opener, [url], { stdio: 'ignore', detached: true, shell: process.platform === 'win32' }).unref();
    return null;
  }
  const app = CHROMIUM_APPS.flatMap((n) => [`/Applications/${n}.app`, path.join(os.homedir(), `Applications/${n}.app`)].map((p) => ({ n, p }))).find((a) => fs.existsSync(a.p));
  if (!app) {
    spawn('open', [url], { stdio: 'ignore', detached: true }).unref();
    return null;
  }
  const args = [`--app=${url}`, `--user-data-dir=${path.join(DATA_DIR, 'window-profile')}`, '--no-first-run', '--no-default-browser-check', '--autoplay-policy=no-user-gesture-required', '--window-size=1440,900'];
  const child = spawn(path.join(app.p, 'Contents/MacOS', app.n), args, { stdio: 'ignore', detached: !own });
  child.on('error', (e) => console.warn(`[window] ${app.n}: ${e.message}`));
  if (!own) child.unref();
  return child;
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(import.meta.filename)) {
  openWindow(process.argv[2] || `http://localhost:${process.env.PORT || 8484}`);
}
