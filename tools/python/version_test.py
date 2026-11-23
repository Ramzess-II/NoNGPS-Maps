#!/usr/bin/env python3
"""Tests of tools/unix/version.sh.

The Android versionCode has to stay inside the RR_yy_MM_dd_CC layout the script documents. A third digit in CC
shifts the whole code left, and android/wear/build.gradle, which multiplies the code by ten for the Wear OS
artifact, then passes the signed int Gradle keeps a versionCode in: that is how a day with 100 commits broke every
Android build. The Huawei flavor of android/app/build.gradle adds the market field RR of the layout to the same
code, so both that offset and the Wear OS factor are checked here.
"""

import os
import re
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VERSION_SH = os.path.join(ROOT, "tools", "unix", "version.sh")
WEAR_GRADLE = os.path.join(ROOT, "android", "wear", "build.gradle")
APP_GRADLE = os.path.join(ROOT, "android", "app", "build.gradle")

INT_MAX = 2**31 - 1
PLAY_MAX = 21_00_00_00_00  # The greatest versionCode Google Play takes.

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


def wear_code(code):
    """The versionCode android/wear/build.gradle derives from the phone one."""
    with open(WEAR_GRADLE, encoding="utf-8") as gradle:
        formula = re.search(r"versionCode rootProject\.ext\.versionCode \* (\d+) \+ (\d+)", gradle.read())
    assert formula, "the Wear OS versionCode is written another way now: check that it still fits an int"
    return code * int(formula.group(1)) + int(formula.group(2))


def huawei_base():
    """The offset android/app/build.gradle adds to the phone versionCode for the Huawei flavor."""
    with open(APP_GRADLE, encoding="utf-8") as gradle:
        literal = re.search(r"HUAWEI_VERSION_CODE_BASE\s*=\s*([0-9_]+)", gradle.read())
    assert literal, "the Huawei offset is written another way now: check that it is still the RR field"
    digits = literal.group(1).replace("_", "")
    # A literal with a leading zero is octal in Groovy as in Java, which is not what the layout means.
    return int(digits, 8 if digits.startswith("0") else 10)


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

    def test_the_wear_os_code_fits_an_int(self):
        with tempfile.TemporaryDirectory() as repo:
            # The script reads at most 128 commits, so this is the greatest count it can report, on the
            # last day it can report: the code of the year 2099 with the cap in place.
            make_repo(repo, 128, date="2099-12-31T12:00:00+0000")
            code = int(version(repo, "android_code"))
            self.assertEqual(code, 99_12_31_99)
            self.assertLessEqual(wear_code(code), min(INT_MAX, PLAY_MAX))

    def test_the_huawei_offset_is_the_market_field(self):
        # The flavor takes RR = 01 of RR_yy_MM_dd_CC, so its offset is one unit of that field, and the
        # greatest code the script can print still leaves the result inside an int and Google Play's ceiling.
        self.assertEqual(huawei_base(), 1_00_00_00_00)
        with tempfile.TemporaryDirectory() as repo:
            make_repo(repo, 128, date="2099-12-31T12:00:00+0000")
            self.assertLessEqual(huawei_base() + int(version(repo, "android_code")), min(INT_MAX, PLAY_MAX))


if __name__ == "__main__":
    unittest.main()
