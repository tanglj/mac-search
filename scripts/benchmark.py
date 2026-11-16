#!/usr/bin/env python3
"""测量真实文件扫描或合成百万条索引的查询性能（均包含 CLI 启动）。"""
from __future__ import annotations

import argparse
import json
import math
import pathlib
import platform
import sqlite3
import statistics
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
BINARY = ROOT / ".build" / "release" / "mac-search"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--entries", type=int, default=10_000)
parser.add_argument("--mode", choices=["files", "synthetic"], default="files")
parser.add_argument("--samples", type=int, default=10)
parser.add_argument("--output", type=pathlib.Path)
args = parser.parse_args()
if args.entries < 1 or args.samples < 1:
    parser.error("entries 和 samples 必须为正整数")


def run(*arguments: str):
    result = subprocess.run([str(BINARY), *arguments], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"命令失败（{result.returncode}）：{arguments}\n{result.stderr}")
    return json.loads(result.stdout)


def names(index):
    category = index % 4
    if category == 0:
        return f"document_{index:07d}_annual_report_2026.pdf", "pdf"
    if category == 1:
        return f"客户合同_2026_{index:07d}.docx", "docx"
    if category == 2:
        return f"project_{index:07d}_notes.txt", "txt"
    return f"invoice_{index:07d}_100%_final.xlsx", "xlsx"


with tempfile.TemporaryDirectory(prefix="mac-search-benchmark-") as temp:
    root = pathlib.Path(temp)
    database = root / "index.sqlite"
    base = ("--database", str(database), "--json")
    root_id = run(*base, "roots", "add", str(root))["id"]
    started = time.perf_counter()
    if args.mode == "files":
        for index in range(args.entries):
            (root / names(index)[0]).touch()
        preparation_seconds = time.perf_counter() - started
        started = time.perf_counter()
        reports = run(*base, "index", "rebuild")
        assert reports[0]["entryCount"] == args.entries
    else:
        # Build a query fixture in bulk. This is not a benchmark of normal engine writes.
        print(f"正在批量构造 {args.entries:,} 条合成记录与搜索索引……", flush=True)
        connection = sqlite3.connect(database)
        triggers = connection.execute("SELECT name, sql FROM sqlite_master WHERE type='trigger' AND tbl_name='files'").fetchall()
        for name, _ in triggers:
            connection.execute(f'DROP TRIGGER "{name}"')
        def rows():
            for index in range(args.entries):
                name, extension = names(index)
                yield (root_id, str(root / name), name, str(root), name, extension, 0, 0, 0, 1)
        connection.executemany(
            "INSERT INTO files(root_id,path,name,parent_path,normalized_name,extension,size,modified_at,is_directory,scan_generation) VALUES (?,?,?,?,?,?,?,?,?,?)",
            rows(),
        )
        for _, sql in triggers:
            connection.execute(sql)
        if connection.execute("SELECT value FROM metadata WHERE key='trigram'").fetchone()[0] == "1":
            connection.execute("INSERT INTO files_fts(files_fts) VALUES('rebuild')")
        connection.execute("UPDATE index_roots SET status='ready' WHERE id=?", (root_id,))
        connection.commit()
        connection.close()
        preparation_seconds = None
    indexing_seconds = time.perf_counter() - started
    stats = run(*base, "stats")
    assert stats["entryCount"] == args.entries
    queries = ["annual_report", "0000040", "合同", "客户合同", "100%_", "report 2026", "不存在"]
    results = []
    for query in queries:
        warmup = run(*base, "search", query)
        timings = []
        for _ in range(args.samples):
            started = time.perf_counter()
            found = run(*base, "search", query)
            timings.append((time.perf_counter() - started) * 1000)
            assert found == warmup
        result = {
            "query": query, "returned": len(warmup),
            "p50_ms": round(statistics.median(timings), 2),
            "p95_ms": round(sorted(timings)[math.ceil(len(timings) * .95) - 1], 2),
        }
        print(json.dumps(result, ensure_ascii=False), flush=True)
        results.append(result)
    report = {
        "platform": platform.platform(), "mode": args.mode, "entries": args.entries,
        "preparation_seconds": preparation_seconds,
        "indexing_seconds": round(indexing_seconds, 3), "statistics": stats,
        "samples_per_query": args.samples, "queries": results,
        "limitations": "本机热缓存，含进程启动与 JSON 输出；synthetic 批量导入后重建 FTS，不测扫描或正常写入吞吐，不测冷缓存或峰值内存。",
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
