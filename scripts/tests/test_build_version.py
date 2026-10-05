"""Version/publication regression tests; no compiler, signing, or account access."""

import importlib.util
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest import mock


HELPER_PATH = Path(__file__).resolve().parents[1] / "build-version.py"
SPEC = importlib.util.spec_from_file_location("alpaca_build_version", HELPER_PATH)
build_version = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = build_version
SPEC.loader.exec_module(build_version)


class BuildVersionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "project"
        self.root.mkdir()
        self.build = self.root / "build"
        self.build.mkdir()
        self.stage = self.build / ".AlpacaMusic.test"
        self.stage.mkdir()
        self.source = self.root / "Info.plist"
        self.app = self.build / "AlpacaMusic.app"
        self.candidate = self.stage / "AlpacaMusic.app"
        self.write_source()
        (self.app / "Contents").mkdir(parents=True)
        (self.app / "Contents" / "Info.plist").write_bytes(self.source.read_bytes())
        (self.app / "old-build-marker").write_text("previous working application")

    def write_source(self, version="0.1.9", build="19"):
        # Preserve comments, compact key/value formatting, and unrelated metadata.
        self.original = (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0"><dict>\n'
            '<!-- Example versions 0.1.9 and 19 must stay unchanged. -->\n'
            '<key>CFBundleIdentifier</key><string>dev.byalpaca.music</string>\n'
            f'<key>CFBundleShortVersionString</key><string>{version}</string>\n'
            f'<key>CFBundleVersion</key><string>{build}</string>\n'
            '<key>AlpacaMusicMusicKitConfigured</key><false/>\n'
            '<key>NSAppleMusicUsageDescription</key><string>播放音乐。</string>\n'
            '</dict></plist>\n'
        ).encode("utf-8")
        self.source.write_bytes(self.original)

    @staticmethod
    def versions(path):
        info = plistlib.loads(path.read_bytes())
        return info["CFBundleShortVersionString"], info["CFBundleVersion"]

    def candidate_info(self):
        return self.candidate / "Contents" / "Info.plist"

    def installed_info(self):
        return self.app / "Contents" / "Info.plist"

    def prepare(self, configuration="release"):
        build_version.prepare(self.root, self.stage, configuration)
        (self.candidate / "new-build-marker").write_text("verified candidate")

    def assert_old_app_preserved(self):
        self.assertEqual(
            (self.app / "old-build-marker").read_text(),
            "previous working application",
        )
        self.assertFalse((self.app / "new-build-marker").exists())

    def failing_replace(self, destination):
        """Fail one publication step, while still allowing rollback to run."""
        real_replace = os.replace
        failed = False

        def replace(source, target, *args, **kwargs):
            nonlocal failed
            if Path(target) == destination and not failed:
                failed = True
                raise OSError("simulated publication failure")
            return real_replace(source, target, *args, **kwargs)

        return mock.patch.object(build_version.os, "replace", side_effect=replace)

    def test_prepare_release_only_changes_candidate(self):
        self.prepare()
        self.assertEqual(self.versions(self.candidate_info()), ("0.1.10", "20"))
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assert_old_app_preserved()

    def test_successful_release_publishes_matching_versions(self):
        self.prepare()
        build_version.publish(self.root, self.stage)
        self.assertEqual(self.versions(self.source), ("0.1.10", "20"))
        self.assertEqual(self.versions(self.installed_info()), ("0.1.10", "20"))
        self.assertTrue((self.app / "new-build-marker").exists())
        self.assertFalse((self.app / "old-build-marker").exists())

    def test_source_plist_keeps_its_format_and_unrelated_contents(self):
        self.prepare()
        build_version.publish(self.root, self.stage)
        expected = self.original.replace(
            b"<key>CFBundleShortVersionString</key><string>0.1.9</string>",
            b"<key>CFBundleShortVersionString</key><string>0.1.10</string>",
        ).replace(
            b"<key>CFBundleVersion</key><string>19</string>",
            b"<key>CFBundleVersion</key><string>20</string>",
        )
        self.assertEqual(self.source.read_bytes(), expected)

    def test_debug_publishes_without_incrementing_either_version(self):
        self.prepare("debug")
        self.assertEqual(self.versions(self.candidate_info()), ("0.1.9", "19"))
        build_version.publish(self.root, self.stage)
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertEqual(self.versions(self.installed_info()), ("0.1.9", "19"))
        self.assertTrue((self.app / "new-build-marker").exists())

    def test_later_release_advances_from_last_successful_version(self):
        self.prepare()
        build_version.publish(self.root, self.stage)
        next_stage = self.build / ".AlpacaMusic.second"
        next_stage.mkdir()
        build_version.prepare(self.root, next_stage, "release")
        build_version.publish(self.root, next_stage)
        self.assertEqual(self.versions(self.source), ("0.1.11", "21"))
        self.assertEqual(self.versions(self.installed_info()), ("0.1.11", "21"))

    def test_manually_changed_major_and_minor_are_preserved(self):
        self.write_source(version="2.7.0", build="219")
        self.prepare()
        build_version.publish(self.root, self.stage)
        self.assertEqual(self.versions(self.source), ("2.7.1", "220"))

    def test_temporary_signing_overrides_do_not_leak_into_source(self):
        self.prepare()
        info = plistlib.loads(self.candidate_info().read_bytes())
        info["CFBundleIdentifier"] = "example.temporary.bundle"
        info["AlpacaMusicMusicKitConfigured"] = True
        self.candidate_info().write_bytes(plistlib.dumps(info))
        build_version.publish(self.root, self.stage)
        original_info = plistlib.loads(self.source.read_bytes())
        self.assertEqual(original_info["CFBundleIdentifier"], "dev.byalpaca.music")
        self.assertIs(original_info["AlpacaMusicMusicKitConfigured"], False)
        installed = plistlib.loads(self.installed_info().read_bytes())
        self.assertEqual(installed["CFBundleIdentifier"], "example.temporary.bundle")
        self.assertIs(installed["AlpacaMusicMusicKitConfigured"], True)

    def test_source_changed_during_build_is_preserved_and_publish_refused(self):
        self.prepare()
        changed = self.original.replace(b"dev.byalpaca.music", b"dev.byalpaca.manual")
        self.source.write_bytes(changed)
        with self.assertRaises(ValueError):
            build_version.publish(self.root, self.stage)
        self.assertEqual(self.source.read_bytes(), changed)
        self.assert_old_app_preserved()

    def test_mismatched_candidate_version_is_not_published(self):
        self.prepare()
        info = plistlib.loads(self.candidate_info().read_bytes())
        info["CFBundleShortVersionString"] = "9.9.9"
        self.candidate_info().write_bytes(plistlib.dumps(info))
        with self.assertRaises(ValueError):
            build_version.publish(self.root, self.stage)
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assert_old_app_preserved()

    def test_failed_app_publication_preserves_previous_app_and_source(self):
        self.prepare()
        with self.failing_replace(self.app):
            with self.assertRaises(OSError):
                build_version.publish(self.root, self.stage)
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assert_old_app_preserved()

    def test_failed_source_update_rolls_back_published_app(self):
        self.prepare()
        with self.failing_replace(self.source):
            with self.assertRaises(OSError):
                build_version.publish(self.root, self.stage)
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assert_old_app_preserved()

    def test_failed_source_update_on_first_build_leaves_no_published_app(self):
        import shutil

        shutil.rmtree(self.app)
        self.prepare()
        with self.failing_replace(self.source):
            with self.assertRaises(OSError):
                build_version.publish(self.root, self.stage)
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertFalse(self.app.exists())

    def test_interrupt_after_previous_app_move_keeps_previous_app_recoverable(self):
        self.prepare()
        real_replace = os.replace
        previous = self.stage / "previous.app"
        interrupted = False

        def interrupt_after_move(source, target, *args, **kwargs):
            nonlocal interrupted
            result = real_replace(source, target, *args, **kwargs)
            if Path(target) == previous and not interrupted:
                interrupted = True
                raise InterruptedError("interrupt delivered just after rename")
            return result

        with mock.patch.object(build_version.os, "replace", side_effect=interrupt_after_move):
            with self.assertRaises(InterruptedError):
                build_version.publish(self.root, self.stage)
        self.assertEqual(self.source.read_bytes(), self.original)
        # Either recover immediately, or retain both the backup and cleanup guard.
        if self.app.exists():
            self.assert_old_app_preserved()
        else:
            self.assertTrue((previous / "old-build-marker").exists())
            self.assertTrue((self.stage / "install-in-progress").exists())

    def test_interrupt_after_source_rename_does_not_leave_mismatched_versions(self):
        self.prepare()
        real_replace = os.replace
        interrupted = False

        def interrupt_after_move(source, target, *args, **kwargs):
            nonlocal interrupted
            result = real_replace(source, target, *args, **kwargs)
            if Path(target) == self.source and not interrupted:
                interrupted = True
                raise InterruptedError("interrupt delivered just after rename")
            return result

        with mock.patch.object(build_version.os, "replace", side_effect=interrupt_after_move):
            with self.assertRaises(InterruptedError):
                build_version.publish(self.root, self.stage)
        self.assertEqual(self.versions(self.source), self.versions(self.installed_info()))
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assert_old_app_preserved()

    def test_invalid_marketing_versions_fail_without_mutation(self):
        for version in ("", "1.2", "1.2.3.4", "1.2.x", "-1.2.3"):
            with self.subTest(version=version):
                self.write_source(version=version)
                with self.assertRaises(ValueError):
                    build_version.prepare(self.root, self.stage, "release")
                self.assertEqual(self.source.read_bytes(), self.original)
                self.assert_old_app_preserved()

    def test_invalid_internal_build_numbers_fail_without_mutation(self):
        for build in ("", "0", "-1", "1.2", "release"):
            with self.subTest(build=build):
                self.write_source(build=build)
                with self.assertRaises(ValueError):
                    build_version.prepare(self.root, self.stage, "release")
                self.assertEqual(self.source.read_bytes(), self.original)
                self.assert_old_app_preserved()

    def test_invalid_configuration_fails_without_mutation(self):
        with self.assertRaises(ValueError):
            build_version.prepare(self.root, self.stage, "production")
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assert_old_app_preserved()


if __name__ == "__main__":
    unittest.main()
