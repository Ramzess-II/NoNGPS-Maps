#!/usr/bin/env python3
"""Shows the logs of NonGPS Maps trip by trip in the browser: the map, the tracks, the events, the anomalies and
the state of the navigation at any second, with a time slider.

  nogps_log_viewer.py [logs, zips or folders…] [--year 2026] [--port 8765] [--no-browser]

More logs and a nogps-replay-out.txt of nogps_replay.py are added in the page. The logs stay on this computer: the
server listens on 127.0.0.1 only, and the page loads only the map tiles of OpenStreetMap and its two libraries.
See nogps_log.py for the logs it reads.
"""

import argparse
import json
import os
import re
import threading
import traceback
import webbrowser
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

import nogps_log

PAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'nogps_log_viewer.html')
TRIP_PATH = re.compile(r'^/api/trip/(\d+)(\.csv|\.gpx)?$')
REPLAY_PATH = re.compile(r'^/api/replay/(\d+)$')


class Viewer:
    def __init__(self, sources, year):
        self.year = year
        self.sources = sources
        self.lock = threading.Lock()
        self.analysis = nogps_log.Analysis(sources, year)

    def add(self, name, data, analyse):
        """Adds a log, read with the others when |analyse|: the page sends a few files one by one."""
        with self.lock:
            sources = [s for s in self.sources if s[0] != name] + [(name, data)]
            # A file that can't be read is not kept.
            nogps_log.unpack(name, data)
            if analyse:
                self.analysis = nogps_log.Analysis(sources, self.year)
            self.sources = sources

    def clear(self):
        with self.lock:
            self.sources = []
            self.analysis = nogps_log.Analysis([], self.year)

    def trips(self):
        a = self.analysis
        return dict(files=a.files, notes=a.notes, trips=[t.summary() for t in a.trips])


def handler(viewer):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, body, content_type='application/json', name=None):
            if not isinstance(body, bytes):
                body = (body if isinstance(body, str) else json.dumps(body, separators=(',', ':'))).encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', content_type + '; charset=utf-8')
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
                if url.path == '/api/trips':
                    return self.send(viewer.trips())
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
                    return self.send(trip.details())
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
    parser.add_argument('logs', nargs='*', help='app*.log, log.txt, logs.zip, log.zip or a folder of them')
    parser.add_argument('--year', type=int, help='the year of an Android log without its header')
    parser.add_argument('--port', type=int, default=0, help='0 takes a free one')
    parser.add_argument('--no-browser', action='store_true')
    args = parser.parse_args()

    viewer = Viewer(nogps_log.load_paths(args.logs), args.year)
    for note in viewer.analysis.notes:
        print(note)
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
