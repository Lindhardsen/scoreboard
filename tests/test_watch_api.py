"""API used by the Apple Watch app. Run with: python3 -m unittest discover -s tests -v"""

import json
from pathlib import Path
import runpy
import shutil
import tempfile
import time
import unittest
from unittest.mock import Mock

from werkzeug.security import generate_password_hash


ROOT = Path(__file__).resolve().parents[1]


class WatchApiTests(unittest.TestCase):
    def setUp(self):
        # Exercise the application without reading or changing real users.json or data/.
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        for name in ('server.py', 'password_support.py', 'scraper.py'):
            shutil.copyfile(ROOT / name, self.directory / name)
        (self.directory / 'users.json').write_text(json.dumps({'users': {'test-user': {
            'password_hash': generate_password_hash('pw', method='pbkdf2:sha256:600000'),
            'token': 'tok-123',
        }}}))
        self.ns = runpy.run_path(str(self.directory / 'server.py'))
        app = self.ns['app']
        app.config.update(TESTING=True, SECRET_KEY='test-session-secret')
        self.client = app.test_client()

    def test_token_returned_for_correct_password(self):
        response = self.client.post('/test-user/api/token', data={'password': 'pw'})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json, {'token': 'tok-123'})
        response = self.client.post('/test-user/api/token', json={'password': 'pw'})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json, {'token': 'tok-123'})

    def test_token_rejects_wrong_password_and_records_attempt(self):
        response = self.client.post('/test-user/api/token', data={'password': 'wrong'})
        self.assertEqual(response.status_code, 401)
        self.assertNotIn(b'tok-123', response.data)
        self.assertEqual(len(self.ns['LOGIN_ATTEMPTS']['127.0.0.1']), 1)

    def test_token_rate_limited(self):
        self.ns['LOGIN_ATTEMPTS']['127.0.0.1'].extend([time.time()] * 5)
        response = self.client.post('/test-user/api/token', data={'password': 'pw'})
        self.assertEqual(response.status_code, 429)
        self.assertNotIn(b'tok-123', response.data)

    def test_token_unknown_user_404(self):
        self.assertEqual(self.client.post('/nobody/api/token', data={'password': 'pw'}).status_code, 404)
        self.assertEqual(self.client.post('/Bad_User/api/token', data={'password': 'pw'}).status_code, 404)

    def upload(self, filedata):
        return self.client.post('/test-user/upload.php', data={
            'token': 'tok-123', 'filename': 'scoreboard.xml', 'filedata': filedata,
        })

    def test_upload_writes_json_sidecar(self):
        response = self.upload((ROOT / 'html/scoreboard.xml').read_text(encoding='utf-8'))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data, b'OK')
        expected = {
            'home': {'name': 'Eksjö Volleyboll IK', 'sets': 1, 'points': 12},
            'away': {'name': 'Gislaveds VBK C', 'sets': 0, 'points': 7},
            'matchEnded': False,
        }
        path = self.directory / 'data/test-user/scoreboard.json'
        self.assertEqual(json.loads(path.read_text(encoding='utf-8')), expected)
        self.assertEqual(self.client.get('/test-user/api/score').json, expected)

    def test_upload_with_unparseable_xml_still_ok(self):
        response = self.upload('<div>broken')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data, b'OK')
        self.assertTrue((self.directory / 'data/test-user/scoreboard.xml').exists())
        self.assertFalse((self.directory / 'data/test-user/scoreboard.json').exists())

    def test_upload_escaped_name_round_trips(self):
        xml = (ROOT / 'html/scoreboard.xml').read_text(encoding='utf-8').replace(
            'Eksjö Volleyboll IK', 'A &amp; B')
        self.assertEqual(self.upload(xml).status_code, 200)
        score = json.loads((self.directory / 'data/test-user/scoreboard.json').read_text(encoding='utf-8'))
        self.assertEqual(score['home']['name'], 'A & B')

    def test_upload_reports_running_scraper(self):
        xml = (ROOT / 'html/scoreboard.xml').read_text(encoding='utf-8')
        self.assertNotIn('X-Scraper-Running', self.upload(xml).headers)
        self.ns['_get_user_state']('test-user')['process'] = Mock(poll=Mock(return_value=None))
        self.assertEqual(self.upload(xml).headers.get('X-Scraper-Running'), '1')


if __name__ == '__main__':
    unittest.main()
