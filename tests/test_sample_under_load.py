"""sysobs keeps sampling under heavy load (the Desk #m1020-1547-c8d1).

His 10-20 15:47: "It shouldn't crap out. It's necessary that it keeps going.
It has to take priority."

Four behaviours, each red on 0.2.0 (ca90e92):
  1. a second run that finds the store lock held does not wait 120 s;
  2. the light sample is on disk when the full snapshot is cut off;
  3. priority is raised when the load is over the threshold (stubbed load);
  4. procwatch's job is defined under substrate (install.sh, dry run).

Silent: nothing prints, nothing plays, no real ps is run in-process, and
every store is a throwaway directory. Run one at a time, backgrounded:
    taskpolicy -b nice -n 15 python3 -m unittest tests.test_sample_under_load.<Class>
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import importlib.machinery
import importlib.util
import io
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
SYSOBS = REPO / "bin" / "sysobs"


def load_sysobs(home: Path):
    """A fresh copy of the module whose store is `home`. ROOT is read at
    import, so SYSOBS_HOME is set before the module executes."""
    with mock.patch.dict(os.environ, {"SYSOBS_HOME": str(home)}):
        loader = importlib.machinery.SourceFileLoader(f"sysobs_{id(home)}", str(SYSOBS))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        mod = importlib.util.module_from_spec(spec)
        loader.exec_module(mod)
    return mod


def snapshot_args(**kw) -> argparse.Namespace:
    base = dict(files="none", rdns=False, geo="off", note="test", no_ingest=True,
                no_light=False, json=False)
    base.update(kw)
    return argparse.Namespace(**base)


PS_OUT = (" 101     1  97.0  204800  01:02:03 /usr/bin/hog --spin\n"
          " 202   101   3.5   10240     00:42 /bin/sleep 9\n")


class TestLockHeldDoesNotWait(unittest.TestCase):
    def test_second_run_with_lock_held_returns_at_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            lock = (home / ".store.lock").open("a+")
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)   # "another sysobs"
            try:
                env = dict(os.environ, SYSOBS_HOME=str(home), SYSOBS_BOOST="0")
                # Judged by outcome, not by a stopwatch: under a pegged machine
                # a backgrounded python takes tens of seconds just to start.
                # The old code waited out its 120 s and died with TimeoutError.
                p = subprocess.run(
                    [sys.executable, str(SYSOBS), "snapshot", "--files", "none",
                     "--no-ingest"],
                    capture_output=True, text=True, env=env, timeout=600)
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)
                lock.close()
            self.assertEqual(p.returncode, 0, p.stderr[-400:])
            self.assertIn("full snapshot skipped", p.stdout)
            self.assertTrue(list((home / "light").glob("light-*.ndjson.gz")),
                            "the skipped run still leaves its light sample")
            self.assertNotIn("TimeoutError", p.stderr)
            self.assertFalse((home / "tables" / "snapshot.csv").exists(),
                             "a skipped run must not write the store")


class TestLightSampleSurvivesCutOff(unittest.TestCase):
    def test_light_sample_written_when_full_snapshot_is_cut_off(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            so = load_sysobs(home)
            cut = KeyboardInterrupt("cut off mid-capture")
            with mock.patch.object(so, "_run", return_value=(0, PS_OUT)), \
                 mock.patch.object(so, "load1", return_value=0.0, create=True), \
                 mock.patch.object(so.Capture, "run", side_effect=cut), \
                 contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(KeyboardInterrupt):
                    so.cmd_snapshot(snapshot_args())
            files = list((home / "light").glob("light-*.ndjson.gz"))
            self.assertEqual(len(files), 1, "no light sample on disk after the cut-off")
            recs = so.light_read()
            self.assertEqual(len(recs), 1)
            r = recs[0]
            self.assertEqual(r["status"], "ok")
            self.assertEqual([p[0] for p in r["procs"]], [101, 202])
            self.assertEqual(r["procs"][0][2], 97.0)                 # %cpu
            self.assertEqual(r["procs"][0][3], 204800)               # rss KB
            self.assertEqual(r["procs"][0][4], 3723)                 # etime 01:02:03
            self.assertEqual(r["procs"][0][5], "/usr/bin/hog --spin")
            # and the lock was let go: the next run is not shut out by a dead one
            with (home / ".store.lock").open("a+") as fh:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)


class TestPriorityUnderLoad(unittest.TestCase):
    def _stubs(self, so):
        calls = {"setpriority": [], "qos": 0, "tier": 0}
        return calls, [
            mock.patch.object(so, "_setpriority", create=True,
                              side_effect=lambda *a: calls["setpriority"].append(a)),
            mock.patch.object(so, "_thread_qos_user_interactive", create=True,
                              side_effect=lambda: calls.__setitem__("qos", calls["qos"] + 1) or True),
            mock.patch.object(so, "_tier_self", create=True,
                              side_effect=lambda tp: calls.__setitem__("tier", calls["tier"] + 1) or 0),
        ]

    def test_raised_over_threshold_and_children_wrapped(self):
        with tempfile.TemporaryDirectory() as tmp:
            so = load_sysobs(Path(tmp))
            calls, stubs = self._stubs(so)
            with contextlib.ExitStack() as st:
                for s in stubs:
                    st.enter_context(s)
                st.enter_context(mock.patch.dict(os.environ, {"SYSOBS_BOOST": "1"}))
                st.enter_context(mock.patch.object(so, "load1", return_value=143.9, create=True))
                b = so.raise_priority(cores=16)
                self.assertTrue(b["active"])
                self.assertIn((so.PRIO_DARWIN_PROCESS, 0, 0), calls["setpriority"])
                self.assertEqual(calls["qos"], 1)
                self.assertEqual(calls["tier"], 1)
                seen = {}

                def fake_run(cmd, **kw):
                    seen["cmd"] = cmd
                    return subprocess.CompletedProcess(cmd, 0, "", "")
                st.enter_context(mock.patch.object(so.subprocess, "run", side_effect=fake_run))
                so._run(["ps", "-Ao", "pid="])
                self.assertEqual(seen["cmd"][1:5], ["-t", "0", "-l", "0"])
                self.assertEqual(seen["cmd"][-3:], ["ps", "-Ao", "pid="])

    def test_not_raised_under_threshold(self):
        with tempfile.TemporaryDirectory() as tmp:
            so = load_sysobs(Path(tmp))
            calls, stubs = self._stubs(so)
            with contextlib.ExitStack() as st:
                for s in stubs:
                    st.enter_context(s)
                st.enter_context(mock.patch.dict(os.environ, {"SYSOBS_BOOST": "1"}))
                st.enter_context(mock.patch.object(so, "load1", return_value=20.0, create=True))
                self.assertFalse(so.raise_priority(cores=16)["active"])
                self.assertEqual(calls, {"setpriority": [], "qos": 0, "tier": 0})
                self.assertEqual(so.boosted_argv(["ps"]), ["ps"])

    def test_full_snapshot_yields_when_calm_and_rises_when_pegged(self):
        """The heavy work is background while the machine is calm, and comes
        out of background the moment the load crosses the threshold."""
        with tempfile.TemporaryDirectory() as tmp:
            so = load_sysobs(Path(tmp))
            calls, stubs = self._stubs(so)
            loads = iter([3.0, 3.0] + [400.0] * 1000)
            with contextlib.ExitStack() as st:
                for s in stubs:
                    st.enter_context(s)
                st.enter_context(mock.patch.dict(os.environ, {"SYSOBS_BOOST": "1"}))
                st.enter_context(mock.patch.object(so, "load1", side_effect=lambda: next(loads),
                                                   create=True))
                so.settle_priority(every=0.02)
                self.assertEqual(calls["setpriority"][0], (so.PRIO_DARWIN_PROCESS, 0, so.PRIO_DARWIN_BG))
                for _ in range(200):
                    if so.BOOST["active"]:
                        break
                    time.sleep(0.02)
            self.assertTrue(so.BOOST["active"], "the snapshot stayed in background under load")
            self.assertEqual(calls["setpriority"][-1], (so.PRIO_DARWIN_PROCESS, 0, 0))

    def test_procwatch_raises_itself_when_load_rises(self):
        with tempfile.TemporaryDirectory() as tmp:
            so = load_sysobs(Path(tmp))
            calls, stubs = self._stubs(so)
            loads = iter([1.0] + [500.0] * 1000)       # calm at start, pegged after

            class FakeWatch:
                def __init__(self, interval):
                    pass

                def baseline(self):
                    return 0

                def tick(self):
                    return []
            with contextlib.ExitStack() as st:
                for s in stubs:
                    st.enter_context(s)
                st.enter_context(mock.patch.dict(os.environ, {"SYSOBS_BOOST": "1"}))
                st.enter_context(mock.patch.object(so, "load1", side_effect=lambda: next(loads),
                                                   create=True))
                st.enter_context(mock.patch.object(so, "PROCWATCH_LOAD_EVERY", 0.05, create=True))
                st.enter_context(mock.patch.object(so, "ProcWatch", FakeWatch))
                st.enter_context(mock.patch.object(so, "spool_write"))
                st.enter_context(contextlib.redirect_stderr(io.StringIO()))
                so.cmd_procwatch(argparse.Namespace(interval=0.02, flush=2.0, seconds=0.5,
                                                    echo=False, quiet=True))
            self.assertTrue(so.BOOST["active"], "procwatch never raised its priority")
            self.assertEqual(calls["tier"], 1)


class TestProcwatchUnderSubstrate(unittest.TestCase):
    def test_install_defines_procwatch_with_sub_enable(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, SYSOBS_SUB="/usr/bin/true", HOME=tmp,
                       SYSOBS_HOME=str(Path(tmp) / "store"))
            p = subprocess.run(["bash", str(REPO / "install.sh"), "--dry-run", "--no-svc",
                                "--prefix", str(Path(tmp) / "prefix")],
                               capture_output=True, text=True, env=env, timeout=120)
            self.assertEqual(p.returncode, 0, p.stderr[-400:])
            lines = [ln for ln in p.stdout.splitlines() if "sub enable" in ln or
                     "/usr/bin/true enable" in ln]
            proc = [ln for ln in lines if " procwatch " in f"{ln} "]
            self.assertEqual(len(proc), 1, p.stdout[-1500:])
            ln = proc[0]
            self.assertIn("--name sysobs-proc", ln)
            interp = ln.split(" -- ", 1)[1].split()[0]
            self.assertTrue(interp.startswith("/"), f"interpreter not absolute: {interp}")
            self.assertNotIn("/Applications/Xcode.app", interp)
            self.assertNotIn("local.sysobs-procwatch.plist", p.stdout)


if __name__ == "__main__":
    unittest.main()
