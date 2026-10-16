// Opens Marquee in its own app-style window (no tabs or address bar).
// Chrome is preferred: it plays the on-the-fly converted streams that
// Safari cannot. Usable on its own: node server/window.js [url]

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { DATA_DIR } from './util.js';

const CHROMIUM_APPS = ['Google Chrome', 'Microsoft Edge', 'Brave Browser', 'Chromium'];

export function openWindow(url) {
  if (process.platform !== 'darwin') {
    const opener = process.platform === 'win32' ? 'start' : 'xdg-open';
    spawn(opener, [url], { stdio: 'ignore', detached: true, shell: process.platform === 'win32' }).unref();
    return;
  }
  const app = CHROMIUM_APPS.flatMap((n) => [`/Applications/${n}.app`, path.join(os.homedir(), `Applications/${n}.app`)]).find((p) => fs.existsSync(p));
  const args = app
    ? ['-na', app, '--args', `--app=${url}`, `--user-data-dir=${path.join(DATA_DIR, 'window-profile')}`, '--no-first-run', '--no-default-browser-check', '--autoplay-policy=no-user-gesture-required', '--window-size=1440,900']
    : [url];
  spawn('open', args, { stdio: 'ignore', detached: true }).unref();
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(import.meta.filename)) {
  openWindow(process.argv[2] || `http://localhost:${process.env.PORT || 8484}`);
}
