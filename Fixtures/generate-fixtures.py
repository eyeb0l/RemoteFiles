#!/usr/bin/env python3
"""Create deterministic synthetic reader/server fixtures in an explicit output directory.

Never scans or modifies an existing remote folder. Usage:
  python3 Fixtures/generate-fixtures.py /private/tmp/remotefiles-fixtures
"""
from pathlib import Path
import argparse

parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)

report = Path(__file__).with_name("agent-report.md").read_text(encoding="utf-8")
parts = [report]
for index in range(40):
    parts.append(f"\n\n# Investigation segment {index + 1:02d}\n\n")
    parts.append(report.replace("# Browse and read: working-preview report", "## Repeated evidence fixture"))
large_report = "".join(parts).encode("utf-8")
assert 100 * 1024 <= len(large_report) <= 200 * 1024, len(large_report)
(args.output / "large-agent-report.md").write_bytes(large_report)
(args.output / "agent-report.md").write_text(report, encoding="utf-8")
(args.output / "empty.md").write_bytes(b"")
(args.output / "invalid-utf8.txt").write_bytes(bytes([0xC3, 0x28]))
(args.output / "binary.txt").write_bytes(b"header\x00payload")
(args.output / "oversized.md").write_bytes(b"x" * (2 * 1024 * 1024 + 1))
(args.output / "Résumé — 分析 notes.txt").write_text("Unicode and spaces remain intact.\n", encoding="utf-8")
(args.output / ".hidden-config").write_text("mode=fixture\n", encoding="utf-8")
(args.output / "empty-folder").mkdir(exist_ok=True)
many = args.output / "1000-entries"
many.mkdir(exist_ok=True)
for index in range(1000):
    (many / f"report-{index + 1}.md").write_text(f"# Report {index + 1}\n", encoding="utf-8")
link = args.output / "report-link.md"
if not link.exists() and not link.is_symlink():
    link.symlink_to("agent-report.md")
print(f"Generated {len(large_report):,}-byte report and edge-case fixtures in {args.output}")
