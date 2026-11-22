#!/usr/bin/env python3
"""Tests of tools/unix/version.sh.

The Android versionCode has to stay inside the RR_yy_MM_dd_CC layout the script documents. A third digit in CC
shifts the whole code left, and what the markets add to it then passes the signed int Gradle keeps a versionCode
in: the Wear OS module multiplies the code by ten, which is how a day with 100 commits broke every Android build.
"""

import os
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VERSION_SH = os.path.join(ROOT, "tools", "unix", "version.sh")

INT_MAX = 2**31 - 1
PLAY_MAX = 21_00_00_00_00  # The greatest versionCode Google Play takes.
HUAWEI_BASE = 1_00_00_00_00  # 01_00_00_00_00 in android/app/build.gradle.
WEAR_FACTOR = 10  # android/wear/build.gradle.

DAY = "2026-11-22T12:00:00+0000"


def make_repo(path, commits, date=DAY):
    """An own git repository with `commits` empty commits, all committed on one day."""
    script = (
        "set -eu\n"
        'git init -q "$1"\n'
        'cd "$1"\n'
        "git config user.email version-test@example.com\n"
        "git config user.name 'Version Test'\n"
        'for i in $(seq 1 "$2"); do git commit -q --allow-empty -m "commit $i"; done\n'
    )
    env = dict(os.environ, GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
    subprocess.run(["bash", "-c", script, "bash", path, str(commits)], check=True, env=env)


def version(path, fmt):
    out = subprocess.run(["bash", VERSION_SH, fmt], cwd=path, check=True, capture_output=True, text=True)
    return out.stdout.strip()


class VersionTest(unittest.TestCase):
    def test_count_of_the_day(self):
        with tempfile.TemporaryDirectory() as repo:
            make_repo(repo, 7)
            self.assertEqual(version(repo, "android_code"), "26112207")
            self.assertEqual(version(repo, "android_name"), "2026.11.22-7")
            self.assertEqual(version(repo, "ios_version"), "2026.11.22")

    def test_count_over_99_keeps_the_code_two_digits(self):
        with tempfile.TemporaryDirectory() as repo:
            make_repo(repo, 100)
            code = version(repo, "android_code")
            self.assertEqual(code, "26112299")
            # The version name keeps the true count, so such a day's builds are still told apart.
            self.assertEqual(version(repo, "android_name"), "2026.11.22-100")

    def test_every_market_fits_an_int(self):
        with tempfile.TemporaryDirectory() as repo:
            # The script reads at most 128 commits, so this is the greatest count it can report, on the
            # last day it can report: the code of the year 2099 with the cap in place.
            make_repo(repo, 128, date="2099-12-31T12:00:00+0000")
            code = int(version(repo, "android_code"))
            self.assertEqual(code, 99_12_31_99)
            self.assertLessEqual(HUAWEI_BASE + code, PLAY_MAX)
            self.assertLessEqual(code * WEAR_FACTOR + 1, INT_MAX)


if __name__ == "__main__":
    unittest.main()
