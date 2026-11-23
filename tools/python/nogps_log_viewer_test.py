#!/usr/bin/env python3
"""Tests of nogps_log_viewer.py: the page loads nothing from the network and tiles come only from --tiles."""

import io
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from http.server import ThreadingHTTPServer

import nogps_log_viewer as v


def serve(tiles):
    server = ThreadingHTTPServer(('127.0.0.1', 0), v.handler(v.Viewer([], None, tiles)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def get(server, path):
    try:
        with urllib.request.urlopen('http://127.0.0.1:%d%s' % (server.server_address[1], path)) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, b''


class ViewerTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.config = v.CONFIG
        v.CONFIG = os.path.join(self.dir.name, 'config.json')
        self.addCleanup(setattr, v, 'CONFIG', self.config)

    def start(self, tiles=None):
        server = serve(tiles)
        self.addCleanup(server.shutdown)
        self.addCleanup(server.server_close)
        return server

    def test_page_refers_to_no_other_host(self):
        server = self.start()
        page = get(server, '/')[1].decode()
        self.assertEqual(re.findall(r'(?:src|href)="(https?://[^"]*)"', page.split('<style>')[0]), [])
        self.assertNotIn('tile.openstreetmap.org', page)
        for name in re.findall(r'(?:src|href)="/assets/([^"]*)"', page):
            self.assertEqual(get(server, '/assets/' + name)[0], 200, name)

    def test_no_tiles_by_default(self):
        server = self.start()
        self.assertEqual(json.loads(get(server, '/api/config')[1])['tiles'], None)
        self.assertEqual(get(server, '/tiles/1/0/0.png')[0], 404)

    def test_assets_only_of_the_folder(self):
        server = self.start()
        self.assertEqual(get(server, '/assets/../nogps_log.py')[0], 404)
        self.assertEqual(get(server, '/assets/README.txt')[0], 404)
        self.assertEqual(get(server, '/assets/images/../../nogps_log.py')[0], 404)
        self.assertEqual(get(server, '/assets/other/leaflet.css')[0], 404)

    def test_layer_control_icon_is_served(self):
        # The collapsed layer control is the only switch of the overlays, and leaflet.css draws it from images/.
        server = self.start()
        self.assertEqual(get(server, '/assets/images/layers.png')[0], 200)
        self.assertEqual(get(server, '/assets/images/layers-2x.png')[0], 200)

    def test_the_map_limits_the_zoom(self):
        # Without a tile layer nothing else limits it, and fitBounds of a trip that stood still gives zoom Infinity.
        page = get(self.start(), '/')[1].decode()
        self.assertRegex(page, r"L\.map\('map', \{[^}]*maxZoom: \d+")

    def test_tile_folder(self):
        os.makedirs(os.path.join(self.dir.name, 't', '3', '4'))
        with open(os.path.join(self.dir.name, 't', '3', '4', '5.png'), 'wb') as f:
            f.write(b'png')
        server = self.start(os.path.join(self.dir.name, 't'))
        self.assertEqual(json.loads(get(server, '/api/config')[1])['tiles'], v.LOCAL_TILES)
        self.assertEqual(get(server, '/tiles/3/4/5.png'), (200, b'png'))
        self.assertEqual(get(server, '/tiles/3/4/6.png')[0], 404)

    def test_tile_choice_is_kept(self):
        self.assertIsNone(v.load_tiles(None))
        folder = os.path.join(self.dir.name, 't')
        os.makedirs(folder)
        self.assertEqual(v.load_tiles(folder), folder)
        self.assertEqual(v.load_tiles(None), folder)
        self.assertIsNone(v.load_tiles('off'))
        self.assertIsNone(v.load_tiles(None))
        with self.assertRaises(SystemExit):
            v.load_tiles(os.path.join(folder, 'missing'))
        with self.assertRaises(SystemExit):
            v.load_tiles('https://example.com/tile.png')


class AddTest(unittest.TestCase):
    @staticmethod
    def log(phone, ms=1):
        return ('LOGFMT 2 ms=%d phone=%s trip=180000 app=a build=1 commit=c om=o\nDatetime: 2026-10-08 18:00:00.000\n'
                % (ms, phone)).encode()

    def test_files_of_the_same_name_of_two_phones_do_not_replace_each_other(self):
        viewer = v.Viewer([], None)
        viewer.add('180000.log', self.log('Pixel_7-a3f9'), False)
        viewer.add('180000.log', self.log('SM_S918B-0b1c'), False)
        self.assertEqual(len(viewer.sources), 2)
        viewer.add('180000.log', self.log('Pixel_7-a3f9'), True)
        self.assertEqual(len(viewer.sources), 2)

    def test_files_of_the_same_name_of_two_days_do_not_replace_each_other(self):
        viewer = v.Viewer([], None)
        viewer.add('180000.log', self.log('Pixel_7-a3f9', 1), False)
        viewer.add('180000.log', self.log('Pixel_7-a3f9', 86400000), False)
        self.assertEqual(len(viewer.sources), 2)

    def test_an_oslog_text_is_read_with_the_phone_of_its_path(self):
        """The page sends the path of a file of a dropped folder as its name."""
        text = b'10-08 18:00:01.000 (main) I/OMcore: nogps/engine.cpp:1 Start(): Start\n'
        viewer = v.Viewer([], None)
        viewer.add('logs/iPhone_14-1a2b/2026-10-08/181500.log', text, True)
        self.assertEqual([f['phone'] for f in viewer.analysis.files], ['iPhone_14-1a2b'])

    def test_an_oslog_text_dropped_alone_is_refused_with_a_hint(self):
        with self.assertRaisesRegex(v.nogps_trip_log.LogFormatError, 'give the logs.zip or the folder'):
            v.Viewer([], None).add('181500.log', b'Datetime: 2026-10-08 18:00:00.000\n', True)

    def test_a_file_of_the_earlier_versions_is_refused(self):
        with self.assertRaises(v.nogps_trip_log.LogFormatError):
            v.Viewer([], None).add('app.log', b'Datetime: 2026-10-08 18:00:00.000\n', True)

    def test_a_file_of_the_earlier_versions_does_not_stop_the_batch(self):
        """The page sends the files one by one: the last one is read with the others, the refused one is noted."""
        viewer = v.Viewer([], None)
        viewer.add('180000.log', self.log('Pixel_7-a3f9')
                   + b'10-08 18:00:01.000 (main) I/OMcore: nogps/engine.cpp:1 Start(): Start\n', False)
        viewer.add('log-07-10-26-Pixel_7-a3f9.log', b'Datetime: 2026-10-07 18:00:00.000\n', True)
        self.assertEqual(len(viewer.sources), 2)
        self.assertEqual([f['name'] for f in viewer.analysis.files], ['180000.log'])
        self.assertEqual([n for n in viewer.analysis.notes if 'Skipped' in n],
                         ['Skipped: log-07-10-26-Pixel_7-a3f9.log: not a log of LOGFMT 2, its first line is not a '
                          'LOGFMT line (logs of the earlier versions are not read)'])

    def test_a_zip_is_read_without_its_file_of_an_earlier_version(self):
        """The zip of a phone that still keeps a file of an earlier version next to the files of the tree."""
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as z:
            z.writestr('logs/log-07-10-26-Pixel_7-a3f9.log', 'Datetime: 2026-10-07 18:00:00.000\n')
            z.writestr('logs/Pixel_7-a3f9/2026-10-08/180000.log', self.log('Pixel_7-a3f9')
                       + b'10-08 18:00:01.000 (main) I/OMcore: nogps/engine.cpp:1 Start(): Start\n')
        viewer = v.Viewer([], None)
        viewer.add('logs.zip', data.getvalue(), True)
        self.assertEqual(len(viewer.sources), 1)
        self.assertEqual([f['phone'] for f in viewer.analysis.files], ['Pixel_7-a3f9'])
        self.assertEqual([n for n in viewer.analysis.notes if 'Skipped' in n],
                         ['Skipped: logs.zip/logs/log-07-10-26-Pixel_7-a3f9.log: not a log of LOGFMT 2, its first '
                          'line is not a LOGFMT line (logs of the earlier versions are not read)'])


NODE = shutil.which('node')

# droppedFiles() and upload() of the page, run outside a browser: the page is read, the two functions are taken out of
# its script and called with a stub of the drop entries and of api(), which prints what each call would send.
PAGE_HARNESS = r"""
import {readFileSync} from 'node:fs';

const html = readFileSync(process.argv[2], 'utf8');
const script = html.slice(html.lastIndexOf('<script>') + '<script>'.length, html.lastIndexOf('</script>'));

// The text of a top-level async function of the page, by counting its braces.
function source(name) {
  const start = script.indexOf('async function ' + name + '(');
  if (start < 0) throw new Error(name + ' is not in the page');
  for (let i = script.indexOf('{', start), depth = 0; i < script.length; ++i) {
    if (script[i] === '{') ++depth;
    else if (script[i] === '}' && --depth === 0) return script.slice(start, i + 1);
  }
  throw new Error(name + ' is not closed');
}

const sent = [];
const page = new Function('$', 'api', 'renderTrips', 'loadTrip',
                          source('droppedFiles') + '\n' + source('upload') + '\nreturn {droppedFiles, upload};')(
  () => ({}),
  async (url, options) => { sent.push({url, body: options.body.name}); return {trips: []}; },
  () => {}, () => {});

const file = (name, relative) => ({name, webkitRelativePath: relative || ''});
const name = path => path.split('/').pop();
const fileEntry = path => (
  {isFile: true, name: name(path), fullPath: path, file: resolve => resolve(file(name(path)))});
const dirEntry = (path, children) => ({
  isFile: false,
  name: name(path),
  fullPath: path,
  createReader() {
    let left = children;
    return {readEntries(resolve) { const batch = left; left = []; resolve(batch); }};
  },
});

async function drop(transfer) {
  sent.length = 0;
  await page.upload(await page.droppedFiles(transfer));
  return sent.slice();
}

const out = {};
out.folder = await drop({items: [{webkitGetAsEntry: () => dirEntry('/logs', [dirEntry('/logs/iPhone_14-1a2b',
  [dirEntry('/logs/iPhone_14-1a2b/2026-10-08', [fileEntry('/logs/iPhone_14-1a2b/2026-10-08/181500.log'),
                                                fileEntry('/logs/iPhone_14-1a2b/2026-10-08/181600.log')])])])}],
                        files: []});
out.file = await drop({items: [{webkitGetAsEntry: () => fileEntry('/180000.log')}], files: [file('180000.log')]});
out.text = await drop({items: [{webkitGetAsEntry: () => null}], files: [file('180000.log')]});
sent.length = 0;
await page.upload([file('181500.log', 'logs/iPhone_14-1a2b/2026-10-08/181500.log')]);
out.picked = sent.slice();

console.log(JSON.stringify(out));
"""


@unittest.skipUnless(NODE, 'node is needed to run the script of the page')
class PageUploadTest(unittest.TestCase):
    """What the page sends to /api/add for a dropped folder, a dropped file and a folder picked in the input."""

    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(directory.cleanup)
        harness = os.path.join(directory.name, 'page.mjs')
        with open(harness, 'w') as f:
            f.write(PAGE_HARNESS)
        run = subprocess.run([NODE, harness, v.PAGE], capture_output=True, text=True)
        if run.returncode:
            raise AssertionError('the script of the page did not run: %s' % run.stderr.strip())
        cls.sent = json.loads(run.stdout)

    @staticmethod
    def query(sent, key):
        return [urllib.parse.parse_qs(urllib.parse.urlparse(s['url']).query)[key][0] for s in sent]

    def test_a_dropped_folder_sends_the_path_of_each_file_inside_it(self):
        """The phone of an OSLog text of iOS comes from the path, so the name of the file alone is not enough."""
        sent = self.sent['folder']
        self.assertEqual(self.query(sent, 'name'), ['logs/iPhone_14-1a2b/2026-10-08/181500.log',
                                                    'logs/iPhone_14-1a2b/2026-10-08/181600.log'])
        self.assertEqual(self.query(sent, 'last'), ['0', '1'])
        self.assertEqual([s['body'] for s in sent], ['181500.log', '181600.log'])

    def test_a_dropped_file_sends_its_name(self):
        self.assertEqual(self.query(self.sent['file'], 'name'), ['180000.log'])
        self.assertEqual([s['body'] for s in self.sent['file']], ['180000.log'])

    def test_a_drop_of_an_item_that_is_no_entry_sends_the_files_of_the_transfer(self):
        self.assertEqual(self.query(self.sent['text'], 'name'), ['180000.log'])
        self.assertEqual([s['body'] for s in self.sent['text']], ['180000.log'])

    def test_a_folder_picked_in_the_input_sends_the_path_inside_it(self):
        self.assertEqual(self.query(self.sent['picked'], 'name'), ['logs/iPhone_14-1a2b/2026-10-08/181500.log'])
        self.assertEqual([s['body'] for s in self.sent['picked']], ['181500.log'])


if __name__ == '__main__':
    unittest.main()
