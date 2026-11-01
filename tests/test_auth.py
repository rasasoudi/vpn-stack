import hashlib
import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location("vpn_auth", Path(__file__).parents[1] / "auth.py")
auth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auth)


class AuthTests(unittest.TestCase):
    def test_valid_and_wrong_password(self):
        salt = bytes.fromhex("00" * 16)
        password = "correct horse battery staple"
        digest = hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1,
                                maxmem=64 * 1024 * 1024)
        entry = {"salt": salt.hex(), "hash": digest.hex()}
        self.assertTrue(auth.verify_password(password, entry))
        self.assertFalse(auth.verify_password("wrong password", entry))

    def test_corrupt_hash_fails_closed(self):
        self.assertFalse(auth.verify_password("anything", {"salt": "not hex", "hash": "00"}))


if __name__ == "__main__":
    unittest.main()
