import hashlib
import os
from pathlib import Path
import tempfile
import unittest
import zipfile
from unittest.mock import patch
from provision_linux import wheel_inventory, run_pip


class InventoryTests(unittest.TestCase):
    def test_pip_environment_cannot_add_another_index_or_config(self):
        with patch.dict(os.environ, {'PIP_EXTRA_INDEX_URL':'https://synthetic.invalid/simple',
                                     'PIP_FIND_LINKS':'/synthetic', 'PIP_CONFIG_FILE':'/synthetic/pip.conf'}), \
             patch('provision_linux.subprocess.run') as run:
            run_pip(['download','--index-url','https://pypi.org/simple','synthetic==1.0'])
            args, kwargs = run.call_args
            self.assertEqual(args[0][1:4], ['-I','-m','pip'])
            self.assertEqual({k:v for k,v in kwargs['env'].items() if k.startswith('PIP_')}, {'PIP_CONFIG_FILE':os.devnull})

    def wheel(self, root, filename='synthetic-1.0-py3-none-any.whl', metadata='Name: Synthetic\nVersion: 1.0\nLicense-Expression: MIT\n'):
        path = Path(root) / filename
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('synthetic-1.0.dist-info/METADATA', metadata)
        return path

    def test_hash_identity_and_license(self):
        with tempfile.TemporaryDirectory() as root:
            path = self.wheel(root)
            row, = wheel_inventory(root)
            self.assertEqual(row['sha256'], hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertEqual((row['name'], row['version'], row['license']), ('synthetic', '1.0', 'MIT'))

    def test_missing_or_unexpected_files_fail(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(ValueError, 'missing_wheels'):
                wheel_inventory(root)
            (Path(root) / 'unexpected.txt').write_text('synthetic')
            with self.assertRaisesRegex(ValueError, 'unexpected_provisioning_file'):
                wheel_inventory(root)

    def test_duplicate_distributions_fail(self):
        with tempfile.TemporaryDirectory() as root:
            self.wheel(root)
            self.wheel(root, 'synthetic-1.0-cp312-cp312-linux_x86_64.whl')
            with self.assertRaisesRegex(ValueError, 'duplicate_wheel_identity'):
                wheel_inventory(root)

    def test_missing_metadata_fails(self):
        with tempfile.TemporaryDirectory() as root:
            with zipfile.ZipFile(Path(root) / 'synthetic.whl', 'w') as archive:
                archive.writestr('unexpected.txt', 'synthetic')
            with self.assertRaisesRegex(ValueError, 'invalid_wheel_metadata'):
                wheel_inventory(root)

    def test_vendor_metadata_is_not_a_second_distribution(self):
        with tempfile.TemporaryDirectory() as root:
            path = self.wheel(root)
            with zipfile.ZipFile(path, 'a') as archive:
                archive.writestr('synthetic/vendor/nested-1.dist-info/METADATA', 'Name: nested\nVersion: 1\n')
            self.assertEqual(len(wheel_inventory(root)), 1)


if __name__ == '__main__':
    unittest.main()
