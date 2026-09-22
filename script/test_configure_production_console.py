import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("configure", Path(__file__).with_name("configure-production-console.py"))
assert spec is not None and spec.loader is not None
configure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(configure)
IMAGE = "sha256:" + "a" * 64
NAME = "/puma-12345678-1234-1234-1234-123456789abc"
TARGET = {"name": NAME, "image": IMAGE, "running": True, "memory": configure.MEMORY_LIMIT_BYTES}


def output(targets=None, image=IMAGE):
    return "ISOLATED_CONSOLE=" + json.dumps({"expected_image": image, "candidates": [TARGET] if targets is None else targets})


class ConsoleConfigurationTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.config = Path(self.directory.name) / "console.env"

    def install(self, stdout=None):
        with patch.object(configure.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output() if stdout is None else stdout)) as run:
            configure.configure("192.0.2.10", "production-abcdef", self.config)
        return run.call_args

    def test_installs_private_exact_allocation_pin_and_preserves_db_selection(self):
        call = self.install()
        self.assertEqual(call.kwargs["env"]["LC_PAPER"], "192.0.2.10")
        self.assertTrue(call.kwargs["check"])
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        result = subprocess.check_output(["bash", "-c", 'source "$1"; printf "%s\\n" "$PROD_INSTANCE_IP" "$PROD_CONTAINER_FILTER" "$PROD_DB_HOST_VAR"', "test", str(self.config)], env={**os.environ, "PROD_INSTANCE_IP": "192.0.2.99", "PROD_DB_HOST_VAR": "DATABASE_HOST"}, text=True)
        self.assertEqual(result.splitlines(), ["192.0.2.10", "^" + NAME + "$", "DATABASE_HOST"])

    def test_missing_ambiguous_or_unverified_destination_never_installs(self):
        for value in ("", "banner only", output([]), output([TARGET, TARGET]), output() + "\n" + output()):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.install(value)
            self.assertFalse(self.config.exists())

    def test_memory_image_running_and_name_guards(self):
        changes = [("memory", v) for v in (0, -1, configure.MEMORY_LIMIT_BYTES + 1, "3000", True)]
        changes += [("image", "sha256:" + "b" * 64), ("running", False), ("name", "/puma-*"), ("name", NAME + "'$(false)")]
        for key, value in changes:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                configure.verify_target(output([{**TARGET, key: value}]))
        with self.assertRaises(ValueError):
            configure.verify_target(output(image="invalid"))

    def test_invalid_parameters_fail_before_ssh(self):
        for ip, tag in (("host.example.com", "production-abcdef"), ("192.0.2.10", "latest"), ("192.0.2.10;false", "production-abcdef")):
            with self.subTest(ip=ip, tag=tag), patch.object(configure.subprocess, "run") as run, self.assertRaises(ValueError):
                configure.configure(ip, tag, self.config)
            run.assert_not_called()

    def test_existing_config_and_symlink_are_preserved(self):
        self.config.write_text("keep me\n")
        with self.assertRaises(ValueError):
            self.install()
        self.assertEqual(self.config.read_text(), "keep me\n")
        self.config.unlink()
        self.config.symlink_to(self.config.parent / "missing")
        with self.assertRaises(ValueError):
            self.install()
        self.assertTrue(self.config.is_symlink())

    def test_repin_is_atomic_and_failed_verification_keeps_old_pin(self):
        self.install()
        previous = self.config.read_bytes()
        with patch.object(configure.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output([]))), self.assertRaises(ValueError):
            configure.configure("192.0.2.11", "production-abcdef", self.config, replace=True)
        self.assertEqual(self.config.read_bytes(), previous)
        with patch.object(configure.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output())):
            configure.configure("192.0.2.11", "production-abcdef", self.config, replace=True)
        self.assertIn("PROD_INSTANCE_IP=192.0.2.11", self.config.read_text())
        self.assertEqual(list(self.config.parent.glob(".console-pin-*")), [])

    def test_ssh_error_never_installs(self):
        with patch.object(configure.subprocess, "run", side_effect=subprocess.CalledProcessError(255, "ssh")), self.assertRaises(subprocess.CalledProcessError):
            configure.configure("192.0.2.10", "production-abcdef", self.config)
        self.assertFalse(self.config.exists())

    def test_concurrent_installer_cannot_be_overwritten(self):
        def concurrent_link(source, destination):
            self.config.write_text("other installer\n")
            raise FileExistsError()
        with patch.object(configure.os, "link", side_effect=concurrent_link), self.assertRaises(FileExistsError):
            self.install()
        self.assertEqual(self.config.read_text(), "other installer\n")
        self.assertEqual(list(self.config.parent.glob(".console-pin-*")), [])

    def test_concurrent_repin_cannot_overwrite_between_compare_and_replace(self):
        self.install()
        original_replace = os.replace

        def attempt_competing_repin(source, destination):
            with patch.object(configure.os, "replace", original_replace):
                with self.assertRaises(BlockingIOError):
                    configure.configure("192.0.2.12", "production-abcdef", self.config, replace=True)
            original_replace(source, destination)

        with patch.object(configure.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output())):
            with patch.object(configure.os, "replace", side_effect=attempt_competing_repin):
                configure.configure("192.0.2.11", "production-abcdef", self.config, replace=True)
        self.assertIn("PROD_INSTANCE_IP=192.0.2.11", self.config.read_text())
        self.assertEqual(list(self.config.parent.glob(".console-pin-*")), [])

    def test_other_process_lock_blocks_ssh_and_release_allows_install(self):
        lock_path = str(self.config) + ".lock"
        child_code = 'import fcntl, sys; f=open(sys.argv[1], "w"); fcntl.flock(f, fcntl.LOCK_EX); print("locked", flush=True); sys.stdin.read()'
        with subprocess.Popen(["python3", "-c", child_code, lock_path], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as child:
            try:
                assert child.stdout is not None
                self.assertEqual(child.stdout.readline().strip(), "locked")
                with patch.object(configure.subprocess, "run") as run, self.assertRaises(BlockingIOError):
                    configure.configure("192.0.2.10", "production-abcdef", self.config)
                run.assert_not_called()
                self.assertFalse(self.config.exists())
            finally:
                child.communicate(timeout=5)
        self.install()
        self.assertTrue(self.config.exists())

    def test_remote_inspection_filters_shopper_and_other_jobs_without_leaking_env(self):
        container = {"Name": NAME, "Image": IMAGE, "State": {"Running": True}, "HostConfig": {"Memory": configure.MEMORY_LIMIT_BYTES}, "Config": {"Env": ["NOMAD_JOB_NAME=web_server_generic", "NOMAD_TASK_NAME=puma", "SECRET=not-for-output"]}}
        shopper = copy.deepcopy(container)
        shopper["Config"]["Env"][0] = "NOMAD_JOB_NAME=web_server_green"
        unrelated = copy.deepcopy(container)
        unrelated["Config"]["Env"][0] = "NOMAD_JOB_NAME=other_web_server_generic"
        responses = [json.dumps([{"Id": IMAGE}]), "1\n2\n3\n", json.dumps([shopper, unrelated, container])]
        stream = io.StringIO()
        with patch.object(subprocess, "check_output", side_effect=responses), patch("sys.argv", ["probe", "example-image"]), contextlib.redirect_stdout(stream):
            exec(configure.REMOTE, {})
        self.assertEqual(configure.verify_target(stream.getvalue()), NAME)
        self.assertNotIn("SECRET", stream.getvalue())
        self.assertNotIn("not-for-output", stream.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
