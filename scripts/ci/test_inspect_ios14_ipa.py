import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path
from inspect_ios14_ipa import inspect


def binary(cpu=0x100000c, platform=2, minimum=0x0e0000):
    return struct.pack('<IIIIIIII', 0xfeedfacf, cpu, 0, 6, 1, 24, 0, 0) + struct.pack('<IIIIII', 0x32, 24, platform, minimum, minimum, 0)


class InspectionTests(unittest.TestCase):
    def check(self, framework):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'test.ipa'
            with zipfile.ZipFile(path, 'w') as z:
                z.writestr('Payload/Runner.app/Info.plist', plistlib.dumps({'CFBundleExecutable': 'Runner', 'MinimumOSVersion': '14.0'}))
                z.writestr('Payload/Runner.app/Runner', binary())
                z.writestr('Payload/Runner.app/Frameworks/Sample.framework/Sample', framework)
            return inspect(path)['errors']

    def test_device(self):
        self.assertEqual(self.check(binary()), [])

    def test_simulator(self):
        self.assertTrue(self.check(binary(platform=7)))

    def test_missing_arm64(self):
        self.assertTrue(self.check(binary(cpu=0x1000007)))

    def test_ios15(self):
        self.assertTrue(self.check(binary(minimum=0x0f0000)))


if __name__ == '__main__':
    unittest.main()
