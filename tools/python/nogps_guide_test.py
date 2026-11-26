#!/usr/bin/env python3
"""Checks of data/nogps_guide.html, the guide "How NonGPS works" that both apps show."""

import os
import unittest
from html.parser import HTMLParser

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'data')
GUIDE = os.path.join(DATA, 'nogps_guide.html')
LANGS = ('en', 'uk')


class Guide(HTMLParser):
    def __init__(self):
        super().__init__()
        self.sections = []  # {'id', 'summary': set(langs), 'body': set(langs)}
        self.urls = []  # (tag, attr, value)
        self.imgs = []
        self._stack = []
        self._cur = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        self._stack.append((tag, a))
        if tag == 'details':
            self._cur = {'id': a.get('id'), 'summary': set(), 'body': set()}
            self.sections.append(self._cur)
        if tag == 'img':
            self.imgs.append(a.get('src'))
        for k in ('src', 'href'):
            if k in a:
                self.urls.append((tag, k, a[k]))
        if self._cur is not None and a.get('lang') in LANGS:
            names = [t for t, _ in self._stack]
            if 'summary' in names:
                self._cur['summary'].add(a['lang'])
            elif any(x.get('class') == 'body' for _, x in self._stack):
                self._cur['body'].add(a['lang'])

    def handle_endtag(self, tag):
        while self._stack:
            t, _ = self._stack.pop()
            if t == tag:
                break
        if tag == 'details':
            self._cur = None


def parse():
    g = Guide()
    with open(GUIDE, encoding='utf8') as f:
        g.feed(f.read())
    return g


class NoGpsGuideTest(unittest.TestCase):
    def test_sections_have_id_and_both_languages(self):
        g = parse()
        self.assertEqual(len(g.sections), 18)
        ids = [s['id'] for s in g.sections]
        self.assertTrue(all(ids))
        self.assertEqual(len(set(ids)), len(ids))
        for s in g.sections:
            self.assertEqual(s['summary'], set(LANGS), s['id'])
            self.assertEqual(s['body'], set(LANGS), s['id'])

    def test_images_exist(self):
        for src in parse().imgs:
            self.assertTrue(os.path.exists(os.path.join(DATA, src)), src)

    def test_no_external_urls_but_https_links(self):
        for tag, attr, value in parse().urls:
            if value.startswith(('http://', 'file:', '//')):
                self.fail('%s %s=%s' % (tag, attr, value))
            if tag == 'img' or attr == 'src':
                self.assertFalse('://' in value, value)
            elif '://' in value:
                self.assertTrue(value.startswith(('https://', 'nogps-guide://')), value)

    def test_intro_link(self):
        self.assertIn(('a', 'href', 'nogps-guide://intro'), parse().urls)


if __name__ == '__main__':
    unittest.main()
