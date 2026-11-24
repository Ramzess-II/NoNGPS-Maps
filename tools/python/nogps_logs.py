#!/usr/bin/env python3
"""Fetches the trip logs of NonGPS Maps from the phones and imports them into SQLite databases, a phone-day each, see
nogps_db.py.

  nogps_logs.py fetch [--to trip-logs] [--device <udid|name|serial>] [--from <folder>]
  nogps_logs.py import logs -o <folder>     # logs/<phone>/<yyyy-MM-dd>/<HHmmss>.log -> <folder>/<phone>-<day>.sqlite
  nogps_logs.py summary <database> ...      # the tables of a database with the number of their rows

fetch copies logs/ and flags/ of both apps (release and debug) from every phone plugged in, or from the devices
named, into the tree <to>/<phone>/<yyyy-MM-dd>/<HHmmss>.log, the flags into <to>/<phone>/<yyyy-MM-dd>/flags/:
  iOS (macOS only): xcrun devicectl, Documents/logs and Documents/flags of the app container of IOS_APPS, on the
    iPhones plugged in by wire, or any one named. An app installed from the App Store has no container to read.
  Android: adb pull of Android/data/<package>/files/logs and flags, of the packages ANDROID_PACKAGES. A phone that
    refuses access to Android/data is reported.
  --from <folder>: a folder of logs/ and flags/ already on disk, an unpacked copy; or a mail of "Send logs" saved into
    a folder: its logs.zip, the .png and .m4a attachments and the text with a line per flag, see mail_container().
A log is copied when it is missing in the tree or the phone's copy is bigger (the last file is still being written);
its phone is that of its LOGFMT line. A flag goes to the day of its name with the phone of that day's logs in the same
app; a changed json (sent) or a bigger png or m4a replaces the local copy. Nothing in the tree is ever deleted: the
phone keeps flags 7 days, the tree is the archive. The phone-days that gained or grew a file are imported into
<to>/db/<phone>-<day>.sqlite, and the trips and the flags of those days are printed.

The text logs are the source of truth and are kept; a database is a cache that is made again by importing. A line the
schema cannot map, or a LOGFMT the tools do not know, fails the import with the file and the line, and leaves the
database of that day as it was. Nothing printed has a coordinate.
"""
import argparse
import collections
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

import nogps_db
import nogps_trip_log

IOS_APPS = ('com.non-gps', 'com.non-gps.debug')
# pm list packages takes a part of the name: ua.nogps.maps, its .debug, .web and the others.
ANDROID_PACKAGES = 'ua.nogps'
DB_FOLDER = 'db'
COPY_TIMEOUT_S = 600
# A phone id as the apps make it, Pixel_7-a3f9: anything else in a LOGFMT line would put a file outside the tree.
PHONE_ID = re.compile(r'^\w[\w.-]*$')
# What merge() counts, in the order of the summary.
COUNTS = ('new logs', 'grown logs', 'new flag files', 'changed flag files', 'logs of the earlier names skipped',
          'OSLog texts without LOGFMT skipped')

# A line of the mail text, as NoGpsFlags.mailLine writes it: FLAG 3 18:01:30 10.50000,20.50000 voice 12 s
MAIL_LINE = re.compile(r'^FLAG (\d+) (\d\d):(\d\d):(\d\d)(?: (-?\d+\.\d+),(-?\d+\.\d+)| no position)'
                       r'(?: voice (\d+) s)?\s*$', re.M)
MAIL_TEXT_EXTENSIONS = ('.txt', '.eml', '.text', '.md')

TABLES = ('file', 'trip', 'sample', 'fix', 'sensor', 'calibration', 'action', 'rule', 'event', 'note', 'flag')


def import_command(args):
    imported = nogps_db.import_tree(args.logs, args.output)
    for path, files in imported:
        print('%s: %d files' % (path, len(files)))
    print('%d databases' % len(imported))


def run(command, timeout=COPY_TIMEOUT_S):
    """(exit code, stdout, stderr) of a command; a command that can't start or ends by the timeout is code -1."""
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        return -1, '', str(e)
    return done.returncode, done.stdout, done.stderr


def read_result(path, key, label, notes):
    """The list |key| of the "result" of a JSON file of devicectl, None with a note when it has none."""
    try:
        with open(path) as f:
            return json.load(f)['result'][key]
    except (OSError, ValueError, KeyError, TypeError) as e:
        notes.append('%s: devicectl gave no %s: %r' % (label, key, e))
        return None


def folder_name(text):
    """|text| as a folder name: a wireless adb serial has ":"."""
    return re.sub(r'[^\w.-]', '_', text)


def ios_containers(devices, folder, notes):
    """[(label, folder of logs/ and flags/)] of the apps IOS_APPS on the iPhones plugged in by wire, or the ones of
    |devices| (an identifier, the UDID or the name), copied into |folder| by devicectl."""
    if not shutil.which('xcrun'):
        notes.append('no xcrun: iOS skipped, it is fetched on macOS')
        return []
    listing = os.path.join(folder, 'devices.json')
    code, _, err = run(['xcrun', 'devicectl', 'list', 'devices', '--json-output', listing], 60)
    if code:
        notes.append('devicectl list devices failed: %s' % err.strip()[-300:])
        return []
    found = read_result(listing, 'devices', 'list devices', notes)
    result = []
    for device in found or []:
        hardware, connection = device.get('hardwareProperties', {}), device.get('connectionProperties', {})
        name = device.get('deviceProperties', {}).get('name', '')
        ids = {device.get('identifier'), hardware.get('udid'), name}
        if hardware.get('reality') != 'physical' or hardware.get('platform') != 'iOS':
            continue
        if devices and not ids & set(devices):
            continue
        if not devices and connection.get('transportType') != 'wired':
            continue
        udid = hardware.get('udid') or device['identifier']
        apps_path = os.path.join(folder, 'apps-%s.json' % udid)
        code, _, err = run(['xcrun', 'devicectl', 'device', 'info', 'apps', '--device', udid, '--json-output',
                            apps_path], 120)
        if code:
            notes.append('%s: devicectl could not list the apps: %s' % (name, err.strip()[-300:]))
            continue
        apps = {a.get('bundleIdentifier'): a for a in read_result(apps_path, 'apps', name, notes) or []}
        for bundle in IOS_APPS:
            if bundle not in apps:
                continue
            label = '%s %s' % (name, bundle)
            if not apps[bundle].get('containerAccessible', True):
                notes.append('%s: the app has no container to read (installed from the App Store)' % label)
                continue
            target = os.path.join(folder, folder_name('%s-%s' % (udid, bundle)))
            os.makedirs(target)
            for part in ('logs', nogps_db.FLAG_FOLDER):
                code, _, err = run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', udid,
                                    '--domain-type', 'appDataContainer', '--domain-identifier', bundle,
                                    '--source', 'Documents/' + part, '--destination', os.path.join(target, part)])
                # A folder the app has not made yet is no error: a build without flags, or nothing logged.
                if code and 'No such file or directory' not in err:
                    notes.append('%s: devicectl could not copy %s: %s' % (label, part, err.strip()[-300:]))
            result.append((label, target))
    return result


def android_containers(devices, folder, notes):
    """[(label, folder of logs/ and flags/)] of the packages ANDROID_PACKAGES on the phones adb sees, or the ones of
    |devices| (serials), pulled into |folder|."""
    if not shutil.which('adb'):
        notes.append('no adb: Android skipped')
        return []
    code, out, err = run(['adb', 'devices'], 60)
    if code:
        notes.append('adb devices failed: %s' % err.strip()[-300:])
        return []
    serials = [line.split('\t')[0] for line in out.splitlines()[1:] if line.endswith('\tdevice')]
    for line in out.splitlines()[1:]:
        if '\t' in line and not line.endswith('\tdevice'):
            notes.append('%s: adb sees it as %s' % tuple(line.split('\t', 1)))
    result = []
    for serial in serials:
        if devices and serial not in devices:
            continue
        code, out, err = run(['adb', '-s', serial, 'shell', 'pm', 'list', 'packages', ANDROID_PACKAGES], 60)
        packages = sorted(line[len('package:'):].strip() for line in out.splitlines() if line.startswith('package:'))
        for package in packages:
            label = '%s %s' % (serial, package)
            files = '/sdcard/Android/data/%s/files' % package
            code, out, err = run(['adb', '-s', serial, 'shell', 'ls', files], 60)
            if 'Permission denied' in out + err:
                notes.append('%s: the phone refuses access to Android/data, nothing fetched' % label)
                continue
            target = os.path.join(folder, folder_name('%s-%s' % (serial, package)))
            os.makedirs(target)
            for part in ('logs', nogps_db.FLAG_FOLDER):
                if part not in out.split():
                    continue
                code, _, pull_err = run(['adb', '-s', serial, 'pull', files + '/' + part, target])
                if code:
                    notes.append('%s: adb pull of %s failed: %s' % (label, part, pull_err.strip()[-300:]))
            result.append((label, target))
    return result


def copy_if(source, target, newer):
    """Copies |source| to |target| when |newer|(source, target) or there is no target. Returns 'new', 'changed' or
    None."""
    exists = os.path.exists(target)
    if exists and not newer(source, target):
        return None
    os.makedirs(os.path.dirname(target), exist_ok=True)
    part = target + '.part'
    shutil.copyfile(source, part)
    os.replace(part, target)
    return 'changed' if exists else 'new'


def bigger(source, target):
    return os.path.getsize(source) > os.path.getsize(target)


def differs(source, target):
    with open(source, 'rb') as a, open(target, 'rb') as b:
        return a.read() != b.read()


def is_mail(folder):
    """Whether |folder| is a saved mail of "Send logs": no logs/ or flags/ folder, but a zip or flag files."""
    if os.path.isdir(os.path.join(folder, 'logs')) or os.path.isdir(os.path.join(folder, nogps_db.FLAG_FOLDER)):
        return False
    if not os.path.isdir(folder):
        return False  # merge() skips a missing path quietly
    return any(name.lower().endswith('.zip') or nogps_db.FLAG_NAME.match(name) for name in os.listdir(folder))


def mail_container(folder, target, notes):
    """Makes in the empty |target| the logs/ and flags/ of an app from a saved mail |folder|: the logs.zip is unpacked
    into logs/, the flags/ get the .png and .m4a attachments named as the app names them <yyyyMMdd-HHmmss>, and a json
    made of the FLAG line of the text whose time is that of the name (n, lat and lon, voice_s; sent, as it was mailed).
    A line no attachment has the time of, and one that two days have it, is told in |notes| and left out."""
    names = sorted(os.listdir(folder))
    for name in names:
        if not name.lower().endswith('.zip'):
            continue
        with zipfile.ZipFile(os.path.join(folder, name)) as archive:
            for member in archive.infolist():
                # Only the folders of the logs; a path out of the tree or of the form of a log is not extracted.
                if member.is_dir() or not nogps_trip_log.TREE_PATH.search(member.filename) \
                        or not member.filename.startswith('logs/') or '..' in member.filename.split('/'):
                    notes.append('%s: %s is no log of the tree, skipped' % (name, member.filename))
                    continue
                path = os.path.join(target, *member.filename.split('/'))
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with archive.open(member) as source, open(path, 'wb') as out:
                    shutil.copyfileobj(source, out)
    text = ''
    for name in names:
        if name.lower().endswith(MAIL_TEXT_EXTENSIONS):
            with open(os.path.join(folder, name), encoding='utf-8', errors='replace') as f:
                text += f.read() + '\n'
    stems = collections.defaultdict(list)
    for name in names:
        m = nogps_db.FLAG_NAME.match(name)
        if m and m.group(2) != 'json':
            stems[m.group(1)].append(name)
    flags = os.path.join(target, nogps_db.FLAG_FOLDER)
    by_time = collections.defaultdict(list)
    for stem in stems:
        by_time[stem[9:]].append(stem)
    matched = set()
    for m in MAIL_LINE.finditer(text):
        n, hh, mm, ss, lat, lon, voice = m.groups()
        candidates = by_time.get(hh + mm + ss, [])
        if len(candidates) != 1:
            notes.append('FLAG %s %s:%s:%s: %s, skipped' % (n, hh, mm, ss, 'two days have an attachment of that time'
                                                            if candidates else 'no attachment has its time'))
            continue
        stem = candidates[0]
        matched.add(stem)
        values = {'n': int(n), 'voice_s': int(voice or 0), 'sent': True}
        if lat is not None:
            values.update(lat=float(lat), lon=float(lon))
        os.makedirs(flags, exist_ok=True)
        with open(os.path.join(flags, stem + '.json'), 'w', encoding='utf-8') as f:
            json.dump(values, f)
        for name in stems[stem]:
            shutil.copyfile(os.path.join(folder, name), os.path.join(flags, name))
    for stem in sorted(set(stems) - matched):
        notes.append('%s: no FLAG line of the mail text has its time, attachments skipped' % stem)


def merge(container, tree, notes, keep_json=False):
    """Copies the logs/ and flags/ of an app |container| into |tree|. Returns the {(phone, day)} that gained or grew
    a file, and the counts of the files copied. With |keep_json| a flag json of the tree is not replaced: the one made
    of a mail has less than the one of a phone."""
    changed = set()
    counts = collections.Counter()
    day_phones = collections.defaultdict(collections.Counter)
    logs = os.path.join(container, 'logs')
    for path in nogps_trip_log.log_files([logs]) if os.path.isdir(logs) else []:
        relative = os.path.relpath(path, logs).replace(os.sep, '/')
        if not nogps_trip_log.TREE_PATH.fullmatch(relative):
            counts['logs of the earlier names skipped'] += 1
            continue
        try:
            header = nogps_trip_log.read_header(path)
        except nogps_trip_log.LogFormatError as e:
            notes.append('%s, skipped' % e)
            continue
        if header['logfmt'] is None:
            counts['OSLog texts without LOGFMT skipped'] += 1
            continue
        if not PHONE_ID.match(header['phone']):
            notes.append('%s: the phone id %r is no folder name, skipped' % (relative, header['phone']))
            continue
        day = os.path.basename(os.path.dirname(path))
        day_phones[day][header['phone']] += 1
        done = copy_if(path, os.path.join(tree, header['phone'], day, os.path.basename(path)), bigger)
        if done:
            counts['grown logs' if done == 'changed' else 'new logs'] += 1
            changed.add((header['phone'], day))
    flags = os.path.join(container, nogps_db.FLAG_FOLDER)
    every_phone = sum(day_phones.values(), collections.Counter())
    for name in sorted(os.listdir(flags)) if os.path.isdir(flags) else []:
        m = nogps_db.FLAG_NAME.match(name)
        if not m:
            continue
        stem = m.group(1)
        day = '%s-%s-%s' % (stem[:4], stem[4:6], stem[6:8])
        # The phone id is of the app: a day without logs takes the phone of the other days, when there is one.
        phones = day_phones.get(day) or (every_phone if len(every_phone) == 1 else None)
        if not phones:
            notes.append('flags/%s: no log of its day tells its phone, skipped' % name)
            continue
        phone = phones.most_common(1)[0][0]
        done = copy_if(os.path.join(flags, name), os.path.join(tree, phone, day, nogps_db.FLAG_FOLDER, name),
                       (lambda *_: False) if keep_json and m.group(2) == 'json'
                       else differs if m.group(2) == 'json' else bigger)
        if done:
            counts['changed flag files' if done == 'changed' else 'new flag files'] += 1
            changed.add((phone, day))
    return changed, counts


def import_days(tree, days, notes):
    """Imports the |days| {(phone, day)} of |tree| into <tree>/db. Returns {(phone, day): what came of it}."""
    result = {}
    for phone, day in sorted(days):
        folder = os.path.join(tree, phone, day)
        try:
            imported = nogps_db.import_tree([folder], os.path.join(tree, DB_FOLDER))
            # A day of flags only has no database: the database is of the logs.
            result[(phone, day)] = 'imported' if imported else 'no logs, not imported'
        except (nogps_db.ImportError_, nogps_trip_log.LogFormatError) as e:
            notes.append('import of %s %s failed: %s' % (phone, day, e))
            result[(phone, day)] = 'import failed'
    return result


def fetch_command(args):
    notes = []
    changed = set()
    with tempfile.TemporaryDirectory() as folder:
        if args.sources:
            containers = [(source, source) for source in args.sources]
        else:
            containers = ios_containers(args.device, folder, notes) + android_containers(args.device, folder, notes)
        if not containers:
            notes.append('no phone with the app found')
        for label, container in containers:
            mailed = args.sources and is_mail(container)
            if mailed:
                unpacked = tempfile.mkdtemp(dir=folder)
                mail_container(container, unpacked, notes)
            days, counts = merge(unpacked if mailed else container, args.to, notes, keep_json=bool(mailed))
            changed |= days
            print('%s: %s' % (label, ', '.join('%d %s' % (counts[what], what) for what in COUNTS if counts[what])
                               or 'nothing new'))
    imported = import_days(args.to, changed, notes)
    for (phone, day), what in sorted(imported.items()):
        print('%s %s: %s' % (phone, day, what))
    for note in notes:
        print('note:', note)
    if changed:
        # The analyser is loaded only when there is something to show: it is the slow part.
        import nogps_log
        folders = [os.path.join(args.to, phone, day) for phone, day in sorted(changed)]
        try:
            analysis = nogps_log.Analysis(nogps_log.load_paths(folders), flags=nogps_log.load_flags(folders))
        except nogps_trip_log.LogFormatError as e:
            print('note: %s' % e)
        else:
            print()
            nogps_log.print_trips(analysis, False)
            print()
            nogps_log.print_flags(analysis)
    if 'import failed' in imported.values():
        sys.exit(1)


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
    fetch = commands.add_parser('fetch', help='copy the logs and flags of the phones into the tree and import them')
    fetch.add_argument('--to', default='trip-logs', help='the tree, trip-logs by default')
    fetch.add_argument('--device', action='append', help='an iPhone (identifier, UDID or name) or an Android serial; '
                       'every phone plugged in without it')
    fetch.add_argument('--from', dest='sources', action='append', help='a folder of logs/ and flags/ on disk, or a '
                       'saved mail of Send logs, instead of the phones')
    fetch.set_defaults(run=fetch_command)
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
