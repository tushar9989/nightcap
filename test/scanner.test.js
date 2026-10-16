import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { scanLibrary, parseEpisode, parseTitle, seasonNumber } from '../server/scanner.js';

function tree(files) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'marquee-scan-'));
  for (const f of files) {
    const p = path.join(root, f);
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, '');
  }
  return root;
}

const scan = async (root, kind = 'auto') => {
  const lib = await scanLibrary([{ id: 'f', path: root, kind }]);
  const describe = (t) => ({
    kind: t.kind,
    name: t.name,
    year: t.year,
    seasons: t.seasons.map((s) => [s.name, s.episodes.map((id) => lib.files[id].name)]),
  });
  return lib.titles.map(describe);
};

test('show folder with seasons, films and extras', async () => {
  const root = tree([
    'The X-Files Season 1, 2 & 3 + Extras DVDRip/Season 01/The X-Files Season 01 Episode 02 - Deep Throat.avi',
    'The X-Files Season 1, 2 & 3 + Extras DVDRip/Season 01/The X-Files Season 01 Episode 01 - Pilot.avi',
    'The X-Files Season 1, 2 & 3 + Extras DVDRip/Season 01/The X-Files Season 01 Episode 01 - Pilot.srt',
    'The X-Files Season 1, 2 & 3 + Extras DVDRip/Season 02/The X-Files Season 02 Episode 10 - Red Museum.avi',
    'The X-Files Season 1, 2 & 3 + Extras DVDRip/Season 02/The X-Files Season 02 Episode 9 - Firewalker.avi',
    'The X-Files Season 1, 2 & 3 + Extras DVDRip/Films/Fight the Future/Fight the Future.avi',
    'The X-Files Season 1, 2 & 3 + Extras DVDRip/Extras/Season 01 Extras/Deleted Scenes/Scene 1.mp4',
    'The X-Files Season 1, 2 & 3 + Extras DVDRip/TSV/Read Me.txt',
    'The X-Files Season 1, 2 & 3 + Extras DVDRip/Season 01/._The X-Files Season 01 Episode 01 - Pilot.avi',
  ]);
  const titles = await scan(root);
  const show = titles.find((t) => t.kind === 'show');
  assert.equal(show.name, 'The X-Files');
  assert.deepEqual(show.seasons, [
    ['Season 1', ['Pilot', 'Deep Throat']],
    ['Season 2', ['Firewalker', 'Red Museum']],
    ['Extras', ['Season 01 Extras › Scene 1']],
  ]);
  assert.deepEqual(titles.filter((t) => t.kind === 'movie').map((t) => t.name), ['Fight the Future']);
  const lib = await scanLibrary([{ id: 'f', path: root, kind: 'auto' }]);
  const pilot = Object.values(lib.files).find((f) => f.name === 'Pilot');
  assert.equal(pilot.subs.length, 1);
});

test('flat release-style episodes become one season', async () => {
  const root = tree(['Breaking.Bad.S01.720p/Breaking.Bad.S01E02.Cats.in.the.Bag.720p.mkv', 'Breaking.Bad.S01.720p/Breaking.Bad.S01E01.Pilot.720p.mkv', 'Breaking.Bad.S01.720p/Breaking.Bad.S01E01.sample.mkv']);
  const [show] = await scan(root);
  assert.equal(show.kind, 'show');
  assert.equal(show.name, 'Breaking Bad');
  assert.deepEqual(show.seasons, [['Season 1', ['Pilot', 'Cats in the Bag']]]);
});

test('a TV folder holding several shows', async () => {
  const root = tree(['Friends/Season 1/Friends S01E01.mkv', 'Friends/Season 2/Friends S02E01.mkv', 'Frieren/[Subs] Frieren - 01 [1080p].mkv', 'Frieren/[Subs] Frieren - 02 [1080p].mkv']);
  const titles = await scan(root);
  assert.deepEqual(titles.map((t) => [t.kind, t.name, t.seasons.length]), [['show', 'Friends', 2], ['show', 'Frieren', 1]]);
});

test('movies folder: one title per film, extras ignored', async () => {
  const root = tree(['Inception (2010)/Inception.2010.1080p.BluRay.x264.mkv', 'Inception (2010)/Featurettes/Making of.mkv', 'The.Matrix.1999.1080p.mkv']);
  const titles = await scan(root);
  assert.deepEqual(titles.map((t) => [t.kind, t.name, t.year]), [['movie', 'Inception', 2010], ['movie', 'The Matrix', 1999]]);
});

test('a season folder added on its own is named after the show', async () => {
  const root = tree(['Severance/Season 2/Severance S02E01.mkv', 'Severance/Season 2/Severance S02E02.mkv']);
  const [show] = await scan(path.join(root, 'Severance', 'Season 2'));
  assert.equal(show.name, 'Severance');
  assert.deepEqual(show.seasons.map((s) => s[0]), ['Season 2']);
});

test('name parsing', () => {
  assert.deepEqual(parseEpisode('The X-Files Season 09 Episode 19 & 20 - The Truth'), { season: 9, episode: 19, title: 'The Truth', strong: true });
  assert.equal(parseEpisode('Show 1x05 The Thing').episode, 5);
  assert.equal(parseEpisode('[Group] Show - 03 [1080p]').episode, 3);
  assert.equal(parseEpisode('The X-Files Season 03 Episode 03 - D.P.O').title, 'D.P.O');
  assert.deepEqual(parseTitle('Blade.Runner.2049.2017.1080p.BluRay'), { name: 'Blade Runner 2049', year: 2017 });
  assert.equal(seasonNumber('Specials'), 0);
  assert.equal(seasonNumber('Show.S03.720p'), 3);
  assert.equal(seasonNumber('Extras'), null);
});

test('season release folders of one show merge into one show', async () => {
  const root = tree(['Breaking.Bad.S01.720p.BluRay/Breaking.Bad.S01E01.720p.mkv', 'Breaking.Bad.S02.720p.BluRay/Breaking.Bad.S02E01.720p.mkv', 'Breaking Bad/Breaking Bad Season 3/Breaking.Bad.S03E01.mkv']);
  const titles = await scan(root);
  assert.equal(titles.length, 1);
  assert.equal(titles[0].name, 'Breaking Bad');
  assert.deepEqual(titles[0].seasons.map((s) => s[0]), ['Season 1', 'Season 2', 'Season 3']);
});

test('loose episode files and single-episode folders group into shows', async () => {
  const root = tree(['Severance.S02E01.1080p.mkv', 'Severance.S02E02.1080p.mkv', 'Some.Movie.2021.1080p.mkv', 'Doctor.Who.2005.S01E05.720p/Doctor.Who.2005.S01E05.720p.mkv', 'Doctor.Who.2005.S01E06.720p/Doctor.Who.2005.S01E06.720p.mkv']);
  const titles = await scan(root);
  assert.deepEqual(titles.map((t) => [t.kind, t.name, t.year, t.seasons.map((s) => `${s[0]}:${s[1].length}`).join()]), [
    ['show', 'Doctor Who', 2005, 'Season 1:2'],
    ['show', 'Severance', null, 'Season 2:2'],
    ['movie', 'Some Movie', 2021, ':1'],
  ]);
});
