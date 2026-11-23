#!/usr/bin/env python3
"""Exercise deferred delivery with an isolated fake app, signer, launchd and iPhone."""
import datetime as dt
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location("renew", Path(__file__).with_name("renew-ios.py"))
renew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renew)


class DeferredDeliveryTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        repo = root / "repo"
        helper = repo / "scripts/renew-ios.py"
        helper.parent.mkdir(parents=True)
        helper.write_text("# test helper\n")
        project = repo / "ios/TmuxLink.xcodeproj/project.pbxproj"
        project.parent.mkdir(parents=True)
        project.write_text(renew.WIDGET_BUNDLE)
        lib = repo / "target/aarch64-apple-ios/release/libtmux_link_mobile.a"
        lib.parent.mkdir(parents=True)
        lib.write_bytes(b"pinned library")
        self.base = root / "Renewal"
        self.previous = self.base / "snapshot-old"
        self.previous.mkdir(parents=True)
        self.plist = root / "LaunchAgents/renew.plist"
        self.plist.parent.mkdir()
        self.old_config = {"Label": renew.LABEL, "ProgramArguments":
                           ["python3", str(self.previous / "renew-ios.py"), "check", "test-iphone"]}
        self.plist.write_bytes(plistlib.dumps(self.old_config))
        self.expires = dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=6)
        self.installed = {"device": "test-iphone", "build": "27", "expires": self.expires.isoformat()}
        state = self.base / "state.json"
        state.write_text(json.dumps(self.installed))
        fake_app = root / "built/TmuxLink.app"
        fake_app.mkdir(parents=True)
        (fake_app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": "0.4.2", "CFBundleVersion": "28"}))
        for name, value in {"__file__": str(helper), "BASE": self.base, "PLIST": self.plist,
                            "STATE": state}.items():
            self.patch(renew, name, value)
        self.build = self.patch(renew, "build_release", Mock(return_value=fake_app))
        self.verify = self.patch(renew, "signed_expiration", Mock(return_value=self.expires))
        self.run = self.patch(renew, "run", Mock())
        self.system = self.patch(renew.subprocess, "run", Mock(return_value=subprocess.CompletedProcess([], 0)))

    def patch(self, obj, name, value):
        replacement = patch.object(obj, name, value)
        self.addCleanup(replacement.stop)
        return replacement.start()

    def queue(self):
        renew.setup("test-iphone", queue=True)
        config = plistlib.loads(self.plist.read_bytes())
        source = Path(config["ProgramArguments"][1]).parent
        self.assertEqual(config["ProgramArguments"][2:], ["check", "test-iphone"])
        self.assertEqual((source / "target/aarch64-apple-ios/release/libtmux_link_mobile.a").read_bytes(),
                         b"pinned library")
        self.assertEqual(json.loads(renew.STATE.read_text()), self.installed)
        self.assertTrue((source / renew.PENDING).exists())
        self.assertEqual(self.verify.call_args.args[0], source / "Release/TmuxLink.app")
        self.assertTrue(self.verify.call_args.args[3])
        self.assertEqual(self.system.call_count, 1)  # bootout, no device probe
        self.assertEqual(self.run.call_count, 1)     # bootstrap, no device install
        self.run.reset_mock()
        self.system.reset_mock()
        return source

    def test_queue_offline_then_install_even_with_unchanged_expiry(self):
        source = self.queue()
        self.system.return_value = subprocess.CompletedProcess([], 1)
        renew.refresh("test-iphone", source, False)
        self.assertTrue((source / renew.PENDING).exists())
        self.assertEqual(json.loads(renew.STATE.read_text()), self.installed)
        self.run.assert_not_called()
        self.system.return_value = subprocess.CompletedProcess([], 0)
        self.run.side_effect = subprocess.CalledProcessError(1, "devicectl install")
        with self.assertRaises(subprocess.CalledProcessError):
            renew.refresh("test-iphone", source, False)
        self.assertTrue((source / renew.PENDING).exists())
        self.assertEqual(json.loads(renew.STATE.read_text()), self.installed)
        self.run.side_effect = None
        renew.refresh("test-iphone", source, False)
        self.assertEqual(self.run.call_args.args[-1], source / "Release/TmuxLink.app")
        self.assertIn("install", self.run.call_args.args)
        self.assertEqual(self.build.call_count, 1)
        self.assertFalse((source / renew.PENDING).exists())
        self.assertEqual(json.loads(renew.STATE.read_text())["build"], "28")
        self.assertEqual(json.loads(renew.STATE.read_text())["expires"], self.installed["expires"])
        self.system.reset_mock()
        renew.refresh("test-iphone", source, False)
        self.system.assert_not_called()

    def test_expired_queued_build_is_resigned_from_its_snapshot(self):
        source = self.queue()
        marker = source / renew.PENDING
        request = json.loads(marker.read_text())
        request["expires"] = "2000-01-01T00:00:00+00:00"
        marker.write_text(json.dumps(request))
        renew.refresh("test-iphone", source, False)
        self.build.assert_called_with(source)
        self.assertEqual(self.build.call_count, 2)
        self.assertEqual(self.verify.call_args.args[0], self.build.return_value)
        self.assertTrue(self.verify.call_args.args[3])
        self.assertEqual(self.run.call_args.args[-1], self.build.return_value)
        self.assertFalse(marker.exists())

    def test_failed_signature_leaves_previous_job_intact(self):
        self.verify.side_effect = RuntimeError("signature verification failed")
        with self.assertRaisesRegex(RuntimeError, "signature"):
            renew.setup("test-iphone", queue=True)
        self.system.assert_not_called()
        self.run.assert_not_called()
        self.assertEqual(plistlib.loads(self.plist.read_bytes()), self.old_config)
        self.assertEqual(list(self.base.glob("snapshot-*")), [self.previous])
        self.assertEqual(json.loads(renew.STATE.read_text()), self.installed)

    def test_bootstrap_failure_restores_previous_job_and_snapshot(self):
        self.run.side_effect = [subprocess.CalledProcessError(1, "bootstrap"), None]
        with self.assertRaises(subprocess.CalledProcessError):
            renew.setup("test-iphone", queue=True)
        self.assertEqual(self.run.call_count, 2)
        self.assertEqual(plistlib.loads(self.plist.read_bytes()), self.old_config)
        self.assertEqual(list(self.base.glob("snapshot-*")), [self.previous])
        self.assertEqual(json.loads(renew.STATE.read_text()), self.installed)


if __name__ == "__main__":
    unittest.main()
