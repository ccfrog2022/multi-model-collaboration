"""Deterministic test worker. Makes no network or model requests."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("--prompt-file")
parser.add_argument("--role", default="probe")
parser.add_argument("--model", default="")
parser.add_argument("--cwd", default=".")
parser.add_argument("--version", action="store_true")
parser.add_argument("--sleep", type=float, default=0)
parser.add_argument("--child", action="store_true")
args = parser.parse_args()
if args.version:
    print("collab-test-adapter 1.0")
    sys.exit(0)
if args.child:
    child = subprocess.Popen([sys.executable, "-B", __file__, "--sleep", "60"])
    print(json.dumps({"childPid": child.pid}), flush=True)
    sys.exit(0)
if args.sleep:
    time.sleep(args.sleep)
    sys.exit(0)

content = Path(args.prompt_file).read_text(encoding="utf-8") if args.prompt_file else ""
root = Path(args.cwd)
if args.role == "executor":
    (root / "value.txt").write_text("42\n", encoding="utf-8")
    final = "Changed value.txt to 42."
elif args.role == "tester":
    assert (root / "value.txt").read_text(encoding="utf-8").strip() == "42"
    final = "Independent check passed: value.txt equals 42."
else:
    final = "Reviewed current subject.\nCOLLAB_VERDICT: " + ("FAIL" if "FAIL_REVIEW" in content else "PASS WITH NITS" if "NITS_REVIEW" in content else "PASS")
if "WRITE_TEST_FILE" in content and args.role == "tester":
    detail = "Independent check: value equals 42; boundary rechecked\n" if "WRITE_TEST_FILE_UPDATED" in content else "Independent check: value equals 42\n"
    (root / "value_check.txt").write_text(detail, encoding="utf-8")
if "OUTSIDE_WRITE" in content:
    (root / "unexpected.txt").write_text("Synthetic out-of-scope change\n", encoding="utf-8")
if "TAMPER_RECORD" in content:
    record = Path(args.prompt_file).parent / "invocation.json"
    record.write_text('{"tampered":true}', encoding="utf-8")
if "MAINTENANCE_WRITE" in content:
    with (root / "AGENTS.md").open("a", encoding="utf-8") as rules:
        rules.write("\nMaintenance fixture: verified collaboration rules.\n")
if "TAMPER_TASK" in content:
    task_file = Path(args.prompt_file).parent.parent.parent / "task.json"
    task_file.write_text("{invalid task fixture", encoding="utf-8")
result = {
    "schemaVersion": 1, "ok": True, "final": final, "model": args.model or "test-fixture",
    "session": {"id": "fixture-repeated" if "REUSE_SESSION" in content else str(uuid.uuid4()), "fresh": True},
    "readOnly": args.role in ("reviewer", "probe"),
    "toolEvents": [], "toolAuditComplete": True,
}
if "FAIL_RESULT" in content:
    result["ok"] = False
print(json.dumps(result))
