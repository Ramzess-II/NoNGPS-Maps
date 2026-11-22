#!/usr/bin/env python3
"""Tests of nogps_log_viewer.py: the page loads nothing from the network and tiles come only from --tiles."""

import json
import os
import re
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
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

    def test_a_file_of_the_earlier_versions_is_refused(self):
        with self.assertRaises(v.nogps_trip_log.LogFormatError):
            v.Viewer([], None).add('app.log', b'Datetime: 2026-10-08 18:00:00.000\n', True)


if __name__ == '__main__':
    unittest.main()
