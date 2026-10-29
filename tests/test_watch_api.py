"""API used by the Apple Watch app. Run with: python3 -m unittest discover -s tests -v"""

import json
from pathlib import Path
import runpy
import shutil
import tempfile
import time
import unittest

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


if __name__ == '__main__':
    unittest.main()
