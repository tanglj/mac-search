#!/usr/bin/env python3
"""在隔离目录验证真实 FSEvents、增量对账及监听中断恢复。"""
from __future__ import annotations

import json
import os
import pathlib
import queue
import signal
import sqlite3
import subprocess
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
BINARY = ROOT / ".build/release/mac-search"


class WatchProcess:
    def __init__(self, database):
        self.updates = []
        self.errors = []
        self.events = queue.Queue()
        self.process = subprocess.Popen(
            [str(BINARY), "--database", str(database), "--json", "index", "watch", "--debounce-ms", "100"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        def consume():
            for line in self.process.stdout:
                try:
                    update = json.loads(line)
                    self.updates.append(update)
                    self.events.put(update)
                except Exception as error:
                    self.errors.append(str(error) + line)
        self.reader = threading.Thread(target=consume, daemon=True)
        self.reader.start()

    def wait_event(self, kind, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise AssertionError(f"监听提前退出：{self.process.stderr.read()}，{self.updates}")
            try:
                event = self.events.get(timeout=.1)
            except queue.Empty:
                continue
            if event["kind"] == kind:
                return event
        raise AssertionError(f"未收到 {kind}：{self.updates[-10:]}")

    def stop(self, sig=signal.SIGTERM):
        if self.process.poll() is None:
            self.process.send_signal(sig)
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
                raise AssertionError("监听未能及时停止")
        self.reader.join(timeout=2)
        stderr = self.process.stderr.read()
        assert self.process.returncode == 0, stderr
        assert not self.errors, self.errors
        assert self.updates[-1]["kind"] == "stopped", self.updates[-3:]


def eventually(predicate, description, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.1)
    raise AssertionError(description)


with tempfile.TemporaryDirectory(prefix="mac-search-watch-") as temporary:
    base = pathlib.Path(temporary)
    data = base / "data"
    other = base / "other"
    data.mkdir()
    other.mkdir()
    # Keep the database in an indexed root to detect self-triggered update loops.
    database = data / "index.sqlite"
    global_args = [str(BINARY), "--database", str(database), "--json"]
    def command(*args):
        result = subprocess.run([*global_args, *args], capture_output=True, text=True)
        assert result.returncode == 0, (args, result.stderr)
        return json.loads(result.stdout)
    def search(query):
        return command("search", query, "--limit", "10000")
    def checkpoint(root_id):
        return next(row for row in command("roots", "list") if row["id"] == root_id)["lastEventID"]

    (data / "stable.txt").write_text("stable")
    nested = data / "nested"
    nested.mkdir()
    (nested / "original.txt").write_text("original")
    data_id = command("roots", "add", str(data))["id"]
    other_id = command("roots", "add", str(other))["id"]
    watcher = WatchProcess(database)
    try:
        watcher.wait_event("started")
        # A mutation after listener start must survive startup enumeration and buffered event processing.
        (nested / "during-startup.txt").write_text("startup")
        watcher.wait_event("ready")
        eventually(lambda: len(search("during-startup")) == 1, "启动期间创建文件丢失")
        assert checkpoint(data_id)
        assert search("index.sqlite") == []
        with sqlite3.connect(database) as connection:
            stable_id = connection.execute("SELECT id FROM files WHERE name='stable.txt'").fetchone()[0]

        started = time.monotonic()
        (nested / "客户合同.pdf").write_text("one")
        eventually(lambda: len(search("客户合同")) == 1, "新增文件未更新")
        print(f"真实 FSEvents 新增可见延迟：{time.monotonic() - started:.2f}s", flush=True)
        (nested / "客户合同.pdf").write_text("longer-content")
        eventually(lambda: search("客户合同")[0]["size"] == 14, "修改元数据未更新")
        (nested / "客户合同.pdf").rename(nested / "新合同.pdf")
        eventually(lambda: not search("客户合同") and len(search("新合同")) == 1, "重命名未更新")
        with sqlite3.connect(database) as connection:
            assert stable_id == connection.execute("SELECT id FROM files WHERE name='stable.txt'").fetchone()[0], "嵌套事件错误触发整根替换"

        moved = data / "moved"
        nested.rename(moved)
        eventually(lambda: search("新合同")[0]["path"] == str((moved / "新合同.pdf").resolve()), "目录移动未更新后代路径")
        (moved / "新合同.pdf").unlink()
        eventually(lambda: not search("新合同"), "删除文件未清理")
        for number in range(400):
            (moved / f"burst_{number:04d}.txt").touch()
        eventually(lambda: len(search("burst_")) == 400, "批量创建未收敛")
        for number in range(200):
            (moved / f"burst_{number:04d}.txt").unlink()
        eventually(lambda: len(search("burst_")) == 200, "批量删除未收敛")

        # Permission failure retains prior records while another root remains operational.
        os.chmod(moved, 0)
        eventually(lambda: any(row["status"] == "error" for row in command("roots", "list")), "权限失败未报告")
        assert len(search("burst_")) == 200
        (other / "unblocked.txt").touch()
        eventually(lambda: len(search("unblocked")) == 1, "一个根目录失败阻塞其他根目录")
        os.chmod(moved, 0o700)
        eventually(lambda: all(row["status"] == "ready" for row in command("roots", "list")), "权限恢复未自动校验")
        (moved / "recovered.txt").touch()
        eventually(lambda: len(search("recovered")) == 1, "权限恢复后监听失效")

        # Recreate a root while the watcher is alive; old indexed rows survive its absence.
        (other / "unblocked.txt").unlink()
        other.rmdir()
        eventually(lambda: next(row for row in command("roots", "list") if row["id"] == other_id)["status"] == "unavailable", "根目录离线未报告")
        assert len(search("unblocked")) == 1
        other.mkdir()
        (other / "returned.txt").touch()
        eventually(lambda: len(search("returned")) == 1 and not search("unblocked"), "根目录恢复未校验")
        watcher.stop(signal.SIGINT)
        watcher = None

        # Changes while no stream is running are reconciled on every restart.
        (moved / "recovered.txt").unlink()
        (moved / "offline-created.txt").touch()
        watcher = WatchProcess(database)
        watcher.wait_event("ready")
        eventually(lambda: len(search("offline-created")) == 1 and not search("recovered"), "重启未恢复离线变化")
        assert search("index.sqlite") == []
        # No recurring writes from the index itself after events settle.
        time.sleep(2)
        updates_before = len(watcher.updates)
        time.sleep(2)
        assert len(watcher.updates) == updates_before, "自身索引产生更新循环"
        watcher.process.kill()
        watcher.process.wait(timeout=10)
        watcher.reader.join(timeout=2)
        watcher = None
        (moved / "after-crash.txt").touch()
        watcher = WatchProcess(database)
        watcher.wait_event("ready")
        eventually(lambda: len(search("after-crash")) == 1, "异常退出后未恢复")
        watcher.stop()
        watcher = None
        command("index", "rebuild")  # confirms writer lock was released on shutdown
    finally:
        os.chmod(data / "moved" if (data / "moved").exists() else data, 0o700)
        if watcher:
            if watcher.process.poll() is None:
                watcher.process.terminate()
                try:
                    watcher.process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    watcher.process.kill()
                    watcher.process.wait()

print("监听集成验证通过：真实文件变化、目录移动、批量变化、权限恢复、多根目录隔离、重启对账及信号停止。")
