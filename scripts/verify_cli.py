#!/usr/bin/env python3
"""隔离验证第一阶段 mac-search CLI 的完整流程。"""
from __future__ import annotations

import json
import fcntl
import pathlib
import signal
import sqlite3
import subprocess
import tempfile
import time


ROOT = pathlib.Path(__file__).resolve().parents[1]
BINARY = ROOT / ".build" / "release" / "mac-search"


def run(*args: str) -> subprocess.CompletedProcess[str]:
    result = subprocess.run([str(BINARY), *args], text=True, capture_output=True)
    if result.returncode:
        raise AssertionError(f"命令失败：{args}\nstdout={result.stdout}\nstderr={result.stderr}")
    return result


def reject(*args: str):
    result = subprocess.run([str(BINARY), *args], text=True, capture_output=True)
    assert result.returncode != 0, args
    assert "错误" in result.stderr, result.stderr
    assert not result.stdout, result.stdout


with tempfile.TemporaryDirectory(prefix="mac-search-verify-") as temp:
    root = pathlib.Path(temp)
    nested = root / "nested"
    nested.mkdir()
    (root / "客户合同终稿.txt").write_text("正文", encoding="utf-8")
    (root / "annual_report_2026.pdf").write_text("PDF", encoding="utf-8")
    (nested / "报告.pdf").write_text("报告", encoding="utf-8")
    database = root / "index.sqlite"
    database_args = ("--database", str(database))

    added = json.loads(run(*database_args, "--json", "roots", "add", str(root)).stdout)
    assert added["path"] == str(root.resolve())
    report = json.loads(run(*database_args, "--json", "index", "rebuild").stdout)
    assert report[0]["entryCount"] == 4

    result = json.loads(run(*database_args, "--json", "search", "报告", "--ext", "pdf").stdout)
    assert [item["name"] for item in result] == ["报告.pdf"]
    result = json.loads(run(*database_args, "--json", "search", "报告", "--directory", str(nested)).stdout)
    assert [item["name"] for item in result] == ["报告.pdf"]
    assert run(*database_args, "search", "--json").stdout == ""
    stats = json.loads(run(*database_args, "--json", "stats").stdout)
    assert stats["entryCount"] == 4

    for bad in [
        ("--database",), ("stats", "--unknown"), ("search", "报告", "--limit", "0"),
        ("search", "报告", "--directory"), ("search", "报告", "--kind", "invalid"),
        ("index", "rebuild", "--root-id", "abc"), ("roots", "add", str(nested)),
        ("index", "watch", "--debounce-ms", "0"), ("index", "watch", "--root-id", "-1"),
        ("index", "watch", "--unknown"),
        ("search", "报告", "--limit", "1", "--limit", "2"),
    ]:
        reject(*database_args, *bad)

    with open(str(database) + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        reject(*database_args, "index", "rebuild")
        assert json.loads(run(*database_args, "--json", "search", "报告").stdout)

    # Observe scanning state before sending SIGINT; verify an interrupted scan cannot replace the snapshot.
    for number in range(5_000):
        (nested / f"cancel_{number}.txt").touch()
    process = subprocess.Popen([str(BINARY), *database_args, "--json", "index", "rebuild"],
                               text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    interrupted = False
    try:
        deadline = time.monotonic() + 15
        while process.poll() is None and time.monotonic() < deadline:
            with sqlite3.connect(database) as connection:
                status = connection.execute("SELECT status FROM index_roots").fetchone()[0]
            if status == "scanning":
                process.send_signal(signal.SIGINT)
                interrupted = True
                break
            time.sleep(.005)
        stdout, stderr = process.communicate(timeout=15)
        assert interrupted and process.returncode != 0, (stdout, stderr)
        assert "取消" in stderr, stderr
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    stats = json.loads(run(*database_args, "--json", "stats").stdout)
    assert stats["entryCount"] == 4
    assert json.loads(run(*database_args, "--json", "search", "cancel").stdout) == []

    run(*database_args, "roots", "remove", str(added["id"]))
    assert json.loads(run(*database_args, "--json", "stats").stdout)["entryCount"] == 0
    assert (root / "客户合同终稿.txt").exists()

print("CLI 验证通过：目录管理、扫描、搜索、过滤、参数错误、写入锁及 SIGINT 取消均正常。")
