#!/usr/bin/env python3
"""Imports the trip logs of NonGPS Maps into SQLite databases, a phone-day each, see nogps_db.py.

  nogps_logs.py import logs -o <folder>     # logs/<phone>/<yyyy-MM-dd>/<HHmmss>.log -> <folder>/<phone>-<day>.sqlite
  nogps_logs.py summary <database> ...      # the tables of a database with the number of their rows

The text logs are the source of truth and are kept; a database is a cache that is made again by importing. A line the
schema cannot map, or a LOGFMT the tools do not know, fails the import with the file and the line, and leaves the
database of that day as it was. Nothing printed has a coordinate.
"""
import argparse
import sys

import nogps_db
import nogps_trip_log

TABLES = ('file', 'trip', 'sample', 'fix', 'sensor', 'calibration', 'action', 'rule', 'event', 'note')


def import_command(args):
    imported = nogps_db.import_tree(args.logs, args.output)
    for path, files in imported:
        print('%s: %d files' % (path, len(files)))
    print('%d databases' % len(imported))


def summary_command(args):
    for path in args.databases:
        conn = nogps_db.open_db(path)
        print('%s: %s' % (path, ', '.join('%s %d' % (t, conn.execute('SELECT COUNT(*) FROM %s' % t).fetchone()[0])
                                          for t in TABLES)))
        conn.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    imp = commands.add_parser('import', help='import the logs of a tree into databases')
    imp.add_argument('logs', nargs='+', help='the tree logs/, or a phone or a day of it')
    imp.add_argument('-o', '--output', required=True, help='the folder of the databases')
    imp.set_defaults(run=import_command)
    summary = commands.add_parser('summary', help='the rows of the tables of databases')
    summary.add_argument('databases', nargs='+')
    summary.set_defaults(run=summary_command)
    args = parser.parse_args()
    try:
        args.run(args)
    except (nogps_db.ImportError_, nogps_trip_log.LogFormatError) as e:
        print('Import failed: %s' % e, file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
