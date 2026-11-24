#!/usr/bin/env python3
"""Shows the logs of NonGPS Maps trip by trip in the browser: the map, the tracks, the events, the anomalies and
the state of the navigation at any second, with a time slider.

  nogps_log_viewer.py [logs, zips or folders…] [--library trip-logs] [--year 2026] [--port 8765] [--no-browser]
                      [--tiles <dir|url|off>]

More logs and a nogps-replay-out.txt of nogps_replay.py are added in the page. The logs stay on this computer: the
server listens on 127.0.0.1 only, and the page loads nothing from the network: its two libraries are in
nogps_log_viewer_assets/ and the tracks are drawn on a plain background. --tiles <dir> draws a map from a folder
of {z}/{x}/{y}.png tiles that you put there. --tiles <url> takes tiles from a server, with {z}/{x}/{y} in the url:
then that server sees which area the trip was in. The choice is kept in ~/.nogps_log_viewer.json; --tiles off
clears it.
--library <tree> adds a panel of the tree nogps_logs.py fetch makes: its phones, their days newest first, each day
with its files and flags. A click on a day loads its logs; a flag plays its voice note and opens its trip at its
second. The server gives only the files inside the tree: a path with "..", or a link out of it, is refused.
See nogps_log.py for the logs it reads.
"""

import argparse
import json
import os
import re
import stat
import threading
import traceback
import webbrowser
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, unquote, urlparse

import nogps_db
import nogps_log
import nogps_trip_log

ASSETS = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'nogps_log_viewer_assets')
ASSET_TYPES = {'.css': 'text/css', '.js': 'text/javascript', '.png': 'image/png'}
CONFIG = os.path.expanduser('~/.nogps_log_viewer.json')
TILE_PATH = re.compile(r'^/tiles/(\d{1,2})/(\d+)/(\d+)\.png$')
LOCAL_TILES = '/tiles/{z}/{x}/{y}.png'
PAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'nogps_log_viewer.html')
TRIP_PATH = re.compile(r'^/api/trip/(\d+)(\.csv|\.gpx)?$')
REPLAY_PATH = re.compile(r'^/api/replay/(\d+)$')
FLAG_PATH = re.compile(r'^/api/flag/([^/]+)/([^/]+)/([^/]+)\.(png|m4a|json)$')
FLAG_TYPES = {'png': 'image/png', 'm4a': 'audio/mp4', 'json': 'application/json'}
DAY = re.compile(r'^\d{4}-\d\d-\d\d$')
RANGE = re.compile(r'^bytes=(\d*)-(\d*)$')


def library_path(library, *parts):
    """The path of |parts| inside the folder |library|, None when a part is not a plain name or the path leads out of
    it, through a link too."""
    if not library or any(not p or p.startswith('.') or '/' in p or '\\' in p or os.path.isabs(p) for p in parts):
        return None
    root = os.path.realpath(library)
    path = os.path.realpath(os.path.join(root, *parts))
    return path if path.startswith(root + os.sep) else None


def library_days(library):
    """The phones of the tree and their days, newest first: [dict(phone, days=[dict(day, files, flags)])]. A file
    tells its start, size and the app build of its LOGFMT line; a flag tells what read_flags() reads, without its
    position."""
    phones = []
    for phone in sorted(os.listdir(library)):
        folder = library_path(library, phone)
        if not folder or not os.path.isdir(folder):
            continue
        days = []
        for day in sorted(os.listdir(folder), reverse=True):
            day_folder = library_path(library, phone, day)
            if not DAY.match(day) or not day_folder or not os.path.isdir(day_folder):
                continue
            files = []
            for name in sorted(os.listdir(day_folder)):
                path = os.path.join(day_folder, name)
                if not name.lower().endswith('.log') or not os.path.isfile(path):
                    continue
                try:
                    header = nogps_trip_log.read_header(path)
                except nogps_trip_log.LogFormatError:
                    header = {}
                files.append(dict(name=name, start=name[:6], size=os.path.getsize(path),
                                  build=' '.join(filter(None, (header.get('app'), header.get('build')))) or None))
            flags = [{k: f[k] for k in ('name', 'local_ms', 'ms', 'n', 'voice_s', 'sent', 'png', 'm4a')}
                     for f in nogps_db.day_flags(day_folder, day)]
            if files or flags:
                days.append(dict(day=day, files=files, flags=flags))
        if days:
            phones.append(dict(phone=phone, days=days))
    return phones


def load_tiles(arg):
    """The tile source: |arg| of --tiles, else the one kept from an earlier run. Returns a folder or a url or None."""
    if arg == 'off':
        arg = None
    elif arg is None:
        try:
            with open(CONFIG) as f:
                return json.load(f).get('tiles')
        except (OSError, ValueError, AttributeError):
            return None
    elif '://' not in arg:
        arg = os.path.abspath(os.path.expanduser(arg))
        if not os.path.isdir(arg):
            raise SystemExit('--tiles: %s is not a folder' % arg)
    elif '{z}' not in arg or '{x}' not in arg or '{y}' not in arg:
        raise SystemExit('--tiles: the url needs {z}, {x} and {y}')
    with open(CONFIG, 'w') as f:
        json.dump(dict(tiles=arg), f)
    return arg


class Viewer:
    def __init__(self, sources, year, tiles=None, flags=(), library=None):
        self.year = year
        self.tiles = tiles
        self.sources = sources
        self.library = library
        # {(phone, day, name): flag}: a day loaded again does not repeat its flags.
        self.flags = {(f['phone'], f['day'], f['name']): f for f in flags}
        self.lock = threading.Lock()
        self.analysis = nogps_log.Analysis(sources, year, list(self.flags.values()))

    def add_day(self, phone, day):
        """Adds the logs and the flags of a day of the library, as the page adds files."""
        folder = library_path(self.library, phone, day)
        if not folder or not DAY.match(day) or not os.path.isdir(folder):
            raise ValueError('no day %s of %s in the library' % (day, phone))
        names = sorted(n for n in os.listdir(folder) if n.lower().endswith('.log'))
        with self.lock:
            for f in nogps_db.day_flags(folder, day):
                self.flags[(phone, day, f['name'])] = dict(f, phone=phone, day=day, folder=folder)
        for i, name in enumerate(names):
            with open(os.path.join(folder, name), 'rb') as f:
                # The path in the tree tells the phone of an OSLog text of iOS, as a dropped folder does.
                self.add('%s/%s/%s' % (phone, day, name), f.read(), i == len(names) - 1)
        if not names:
            with self.lock:
                self.analysis = nogps_log.Analysis(self.sources, self.year, list(self.flags.values()))

    def add(self, name, data, analyse):
        """Adds a log, read with the others when |analyse|: the page sends a few files one by one. A file given again
        replaces the one of the same name, phone, start and trip: the page knows only the name of a file, and trips of
        two phones or two days have files of the same name."""
        with self.lock:
            def identity(source):
                """The (phone, start, trip) of the files of the source that can be read, empty for a source of no
                such file. A file of an earlier version is left out, as nogps_log.load_paths() leaves it out; the
                analysis notes it, and refuses only when no file of any source is left."""
                result = set()
                for n, d in nogps_log.unpack(*source):
                    try:
                        header = nogps_trip_log.header_of(n, d)
                    except nogps_trip_log.LogFormatError:
                        continue
                    result.add(tuple(header[k] for k in ('phone', 'ms', 'trip')))
                return result

            new = (name, data)
            same = identity(new)
            sources = [s for s in self.sources if s[0] != name or identity(s) != same] + [new]
            if analyse:
                self.analysis = nogps_log.Analysis(sources, self.year, list(self.flags.values()))
            self.sources = sources

    def clear(self):
        with self.lock:
            self.sources = []
            self.flags = {}
            self.analysis = nogps_log.Analysis([], self.year)

    def flag_url(self, flag, ext):
        """The address of a file of a flag, None when the flag has none or is not of the library."""
        if not flag.get(ext) or library_path(self.library, flag['phone'], flag['day']) != \
                os.path.realpath(flag['folder']):
            return None
        return '/api/flag/%s/%s/%s.%s' % (quote(flag['phone'], safe=''), flag['day'], flag['name'], ext)

    def flag_json(self, flag):
        """What the page shows of a flag: its position only for the mark on the track."""
        result = {k: flag[k] for k in ('phone', 'day', 'name', 'local_ms', 'ms', 't', 'trip', 'n', 'lat', 'lon',
                                       'voice_s', 'sent')}
        result.update(png=self.flag_url(flag, 'png'), m4a=self.flag_url(flag, 'm4a'))
        return result

    def trips(self):
        a = self.analysis
        return dict(files=a.files, notes=a.notes, trips=[t.summary() for t in a.trips],
                    flags=[self.flag_json(f) for f in a.flags], library=bool(self.library))

    def trip_details(self, trip):
        details = trip.details()
        details['flag_list'] = [self.flag_json(f) for f in trip.flags]
        return details


def handler(viewer):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, body, content_type='application/json', name=None):
            if not isinstance(body, bytes):
                body = (body if isinstance(body, str) else json.dumps(body, separators=(',', ':'))).encode('utf-8')
            self.send_response(200)
            text = content_type.startswith('text/') or content_type in ('application/json', 'application/gpx+xml')
            self.send_header('Content-Type', content_type + ('; charset=utf-8' if text else ''))
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            if name:
                self.send_header('Content-Disposition', 'attachment; filename="%s"' % name)
            self.end_headers()
            self.wfile.write(body)

        def fail(self, code, text):
            body = text.encode('utf-8')
            self.send_response(code)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def send_file(self, path, content_type):
            """A file of the library, with the part of it a Range asks for: Safari plays audio only so."""
            with open(path, 'rb') as f:
                data = f.read()
            m = RANGE.match(self.headers.get('Range', ''))
            if not m or not data or (not m.group(1) and not m.group(2)):
                return self.send(data, content_type)
            if m.group(1):
                first, last = int(m.group(1)), min(int(m.group(2) or len(data) - 1), len(data) - 1)
            else:
                first, last = max(len(data) - int(m.group(2)), 0), len(data) - 1
            if first > last:
                self.send_response(416)
                self.send_header('Content-Range', 'bytes */%d' % len(data))
                self.send_header('Content-Length', '0')
                return self.end_headers()
            self.send_response(206)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Range', 'bytes %d-%d/%d' % (first, last, len(data)))
            self.send_header('Content-Length', str(last - first + 1))
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(data[first:last + 1])

        def trip(self, number):
            trips = viewer.analysis.trips
            return trips[number] if number < len(trips) else None

        def allowed(self, post):
            """Only the page of this server: not another site, nor one renamed to 127.0.0.1 to read the logs."""
            port = self.server.server_address[1]
            if self.headers.get('Host') not in ('127.0.0.1:%d' % port, 'localhost:%d' % port):
                return False
            return not post or self.headers.get('X-NoGPS-Viewer') == '1'

        def do_GET(self):
            url = urlparse(self.path)
            if not self.allowed(False):
                return self.fail(403, 'forbidden')
            try:
                if url.path == '/':
                    with open(PAGE, 'rb') as f:
                        return self.send(f.read(), 'text/html')
                if url.path == '/api/config':
                    tiles = viewer.tiles
                    if tiles and '://' not in tiles:
                        return self.send(dict(tiles=LOCAL_TILES, attribution=''))
                    return self.send(dict(tiles=tiles, attribution='Map tiles: ' + tiles.split('/')[2] if tiles else ''))
                if url.path.startswith('/assets/'):
                    name = url.path[len('/assets/'):]
                    ext = os.path.splitext(name)[1]
                    # Only a file of the folder or of its images/, which leaflet.css asks for: no "..".
                    folder, _, base = name.rpartition('/')
                    if ext not in ASSET_TYPES or folder not in ('', 'images') or base.startswith('.') or \
                            not os.path.isfile(os.path.join(ASSETS, folder, base)):
                        return self.fail(404, 'not found')
                    with open(os.path.join(ASSETS, folder, base), 'rb') as f:
                        return self.send(f.read(), ASSET_TYPES[ext])
                m = TILE_PATH.match(url.path)
                if m:
                    if not viewer.tiles or '://' in viewer.tiles:
                        return self.fail(404, 'no tiles')
                    z, x, y = m.groups()
                    path = os.path.join(viewer.tiles, z, x, y + '.png')
                    if not os.path.isfile(path):
                        return self.fail(404, 'no tile')
                    with open(path, 'rb') as f:
                        return self.send(f.read(), 'image/png')
                if url.path == '/api/trips':
                    return self.send(viewer.trips())
                if url.path == '/api/library':
                    if not viewer.library:
                        return self.fail(404, 'no library: --library <tree>')
                    return self.send(dict(phones=library_days(viewer.library)))
                m = FLAG_PATH.match(url.path)
                if m:
                    phone, day, name = (unquote(g) for g in m.groups()[:3])
                    path = library_path(viewer.library, phone, day, nogps_db.FLAG_FOLDER,
                                        '%s.%s' % (name, m.group(4)))
                    if not path or not DAY.match(day) or not os.path.isfile(path) or \
                            not stat.S_ISREG(os.stat(path).st_mode):
                        return self.fail(404, 'not found')
                    return self.send_file(path, FLAG_TYPES[m.group(4)])
                if url.path == '/api/lines':
                    q = parse_qs(url.query)
                    trip = self.trip(int(q['trip'][0]))
                    if not trip:
                        return self.fail(404, 'no such trip')
                    lines = trip.group.lines_between(int(q['from'][0]), int(q['to'][0]))
                    return self.send([[t, level, raw] for t, level, raw in lines[:2000]])
                m = TRIP_PATH.match(url.path)
                if m:
                    trip = self.trip(int(m.group(1)))
                    if not trip:
                        return self.fail(404, 'no such trip')
                    if m.group(2) == '.csv':
                        return self.send(trip.csv(), 'text/csv', 'trip-%d.csv' % trip.id)
                    if m.group(2) == '.gpx':
                        return self.send(trip.gpx(), 'application/gpx+xml', 'trip-%d.gpx' % trip.id)
                    return self.send(viewer.trip_details(trip))
                self.fail(404, 'not found')
            except Exception:
                self.fail(500, traceback.format_exc())

        def do_POST(self):
            url = urlparse(self.path)
            data = self.rfile.read(int(self.headers.get('Content-Length', 0)))
            if not self.allowed(True):
                return self.fail(403, 'forbidden')
            try:
                if url.path == '/api/add':
                    q = parse_qs(url.query)
                    viewer.add(unquote(q['name'][0]), data, q.get('last', ['1'])[0] == '1')
                    return self.send(viewer.trips())
                if url.path == '/api/library/day':
                    q = parse_qs(url.query)
                    viewer.add_day(q['phone'][0], q['day'][0])
                    return self.send(viewer.trips())
                if url.path == '/api/clear':
                    viewer.clear()
                    return self.send(viewer.trips())
                m = REPLAY_PATH.match(url.path)
                if m:
                    trip = self.trip(int(m.group(1)))
                    if not trip:
                        return self.fail(404, 'no such trip')
                    return self.send(trip.replay(data))
                self.fail(404, 'not found')
            except (ValueError, zipfile.BadZipFile) as e:
                self.fail(400, str(e))
            except Exception:
                self.fail(500, traceback.format_exc())

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('logs', nargs='*', help='the logs tree logs/<phone>/<yyyy-MM-dd>/<HHmmss>.log, '
                        'logs.zip or log files')
    parser.add_argument('--library', help='the tree of nogps_logs.py fetch, trip-logs: a panel of its phones, days '
                        'and flags')
    parser.add_argument('--year', type=int, help='the year of an Android log without its header')
    parser.add_argument('--port', type=int, default=0, help='0 takes a free one')
    parser.add_argument('--no-browser', action='store_true')
    parser.add_argument('--tiles', help='a folder of {z}/{x}/{y}.png tiles, or a tile server url with {z}/{x}/{y}, '
                        'or "off"; kept for the next runs. Without it the map has no tiles')
    args = parser.parse_args()

    try:
        sources = nogps_log.load_paths(args.logs)
    except nogps_trip_log.LogFormatError as e:
        parser.error(str(e))
    if args.library and not os.path.isdir(args.library):
        parser.error('--library: %s is not a folder' % args.library)
    viewer = Viewer(sources, args.year, load_tiles(args.tiles), nogps_log.load_flags(args.logs), args.library)
    for note in viewer.analysis.notes:
        print(note)
    print('tiles:', viewer.tiles or 'none')
    print('%d trips in %d files' % (len(viewer.analysis.trips), len(viewer.analysis.files)))
    server = ThreadingHTTPServer(('127.0.0.1', args.port), handler(viewer))
    url = 'http://127.0.0.1:%d/' % server.server_address[1]
    print('open', url, '- Ctrl+C stops')
    if not args.no_browser:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
