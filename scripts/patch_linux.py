#!/usr/bin/env python3
"""
Patch the Linux Codex app.asar by editing its Electron webview bundle.

This script is designed for on-disk patching and should be re-reviewed after
Codex updates (bundle filenames/hashes can change).

Typical usage when starting from an AppImage:
  1) ./Codex-*.AppImage --appimage-extract
  2) python3 scripts/patch_linux.py --asar squashfs-root/resources/app.asar

You can also point --asar directly at any Codex app.asar on disk.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import re
import struct
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Match

Replacement = str | Callable[[Match[str]], str]


@dataclass(frozen=True)
class PatchRule:
    name: str
    unpatched: re.Pattern[str]
    replacement: Replacement
    patched: re.Pattern[str] | None = None
    expected_replacements: int = 1


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_asar_header_json(path: Path) -> str:
    blob = path.read_bytes()
    json_len = struct.unpack_from("<I", blob, 12)[0]
    header_json = blob[16 : 16 + json_len]
    return hashlib.sha256(header_json).hexdigest()


def run_checked(*args: str, cwd: Path | None = None) -> str:
    proc = subprocess.run(
        list(args),
        cwd=str(cwd) if cwd is not None else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if proc.returncode != 0:
        cmd = " ".join(args)
        raise RuntimeError(f"Command failed ({proc.returncode}): {cmd}\n{proc.stdout}")
    return proc.stdout


def apply_rule(text: str, rule: PatchRule, *, dry_run: bool) -> tuple[str, str]:
    if rule.patched is not None and rule.patched.search(text) and not rule.unpatched.search(text):
        return text, "already"

    if dry_run:
        count = len(list(rule.unpatched.finditer(text)))
        if count == 0 and rule.patched is not None and rule.patched.search(text):
            return text, "already"
        if count != rule.expected_replacements:
            raise RuntimeError(
                f"{rule.name}: expected {rule.expected_replacements} match(es), found {count}"
            )
        return text, "would_apply"

    new_text, replaced = rule.unpatched.subn(rule.replacement, text)
    if replaced == 0 and rule.patched is not None and rule.patched.search(text):
        return text, "already"
    if replaced != rule.expected_replacements:
        raise RuntimeError(
            f"{rule.name}: expected {rule.expected_replacements} replacement(s), got {replaced}"
        )
    return new_text, "applied"


def find_webview_bundle_from_index_html(extracted_root: Path) -> Path:
    index_html = extracted_root / "webview/index.html"
    if not index_html.exists():
        raise RuntimeError(f"Missing expected file: {index_html}")
    html = index_html.read_text("utf-8", errors="strict")

    m = re.search(r'src=["\'][^"\']*assets/(index-[^"\']+\.js)["\']', html)
    if not m:
        raise RuntimeError("Could not locate webview bundle in webview/index.html")
    rel = Path("webview/assets") / m.group(1)
    bundle = extracted_root / rel
    if not bundle.exists():
        raise RuntimeError(f"Bundle referenced by index.html does not exist: {bundle}")
    return bundle


def find_default_asar() -> Path | None:
    candidates = [
        Path("squashfs-root/resources/app.asar"),
        Path("work/extracted/resources/app.asar"),
        Path("work/extracted/Codex.app/Contents/Resources/app.asar"),
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate

    matches = list(Path.cwd().glob("**/app.asar"))
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        raise RuntimeError(
            "Multiple app.asar files found. Pass --asar to choose one: "
            + ", ".join(str(m) for m in matches)
        )
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--asar",
        default=None,
        help="Path to Codex app.asar (default: auto-detect in common locations).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Do not write changes; only validate that patches would apply cleanly.",
    )
    parser.add_argument(
        "--no-beautify",
        action="store_true",
        help="Skip regenerating a .beautified.js copy inside the extracted assets folder.",
    )
    parser.add_argument(
        "--keep-extracted",
        action="store_true",
        help="Do not delete the extracted folder (for manual inspection).",
    )
    args = parser.parse_args()

    app_asar = Path(args.asar).expanduser() if args.asar else find_default_asar()
    if app_asar is None:
        print("ERROR: app.asar not found. Pass --asar to specify it.", file=sys.stderr)
        return 2
    if not app_asar.exists():
        print(f"ERROR: not found: {app_asar}", file=sys.stderr)
        return 2

    def repl_exploration_drop_reasoning(m: Match[str]) -> str:
        item = m.group("item")
        buf = m.group("buf")
        close = m.group("close")
        return (
            f'if({item}.type==="reasoning"){{{buf}&&{close}("explored")}}'
            f'{buf}&&{close}("explored")'
        )

    def repl_exploration_no_autocollapse(m: Match[str]) -> str:
        cb = m.group("cb")
        cond = m.group("cond")
        setter = m.group("setter")
        return f'{cb}=()=>{{{cond}&&{setter}("preview")}}'

    def repl_show_reasoning_items(m: Match[str]) -> str:
        render = m.group("render")
        child = m.group("child")
        return f"{render}={child}"

    def repl_no_autocollapse_reasoning(m: Match[str]) -> str:
        stream = m.group("stream")
        el = m.group("el")
        ref = m.group("ref")
        return f"if(!{stream}){{return}}const {el}={ref}.current;"

    def repl_autoscroll_user_scroll_flag(m: Match[str]) -> str:
        el = m.group("el")
        ref = m.group("ref")
        return (
            f"const {el}={ref}.current;"
            f"{el}&&(!{el}.__codexReasoningAutoScrollInit&&("
            f"{el}.__codexReasoningAutoScrollInit=1,"
            f"{el}.__codexReasoningAutoScrollEnabled=1,"
            f'{el}.addEventListener(\"scroll\",()=>{{'
            f"{el}.__codexReasoningAutoScrollEnabled="
            f"{el}.scrollHeight-{el}.clientHeight-{el}.scrollTop<16"
            f"}},{{passive:!0}})"
            f"),"
            f"{el}.__codexReasoningAutoScrollEnabled&&({el}.scrollTop={el}.scrollHeight))"
        )

    patches: list[PatchRule] = [
        PatchRule(
            name="exploration_continuation_drop_reasoning",
            unpatched=re.compile(
                r'if\((?P<item>\w+)\.type==="reasoning"\)\{(?P<buf>\w+)\&\&(?:'
                r'(?P=buf)\.push\((?P=item)\);continue|pt\("explored"\)'
                r')\}(?P=buf)\&\&(?P<close>\w+)\("explored"\)'
            ),
            patched=re.compile(
                r'if\(\w+\.type==="reasoning"\)\{\w+\&\&(?P<close>\w+)\("explored"\)\}\w+\&\&(?P=close)\("explored"\)'
            ),
            replacement=repl_exploration_drop_reasoning,
        ),
        PatchRule(
            name="exploration_no_autocollapse_on_finish",
            unpatched=re.compile(
                r'(?P<cb>\w+)=\(\)=>\{(?P<setter>\w+)\((?P<cond>\w+)\?"preview":"collapsed"\)\}'
            ),
            patched=re.compile(r'(?P<cb>\w+)=\(\)=>\{\w+\&\&\w+\("preview"\)\}'),
            replacement=repl_exploration_no_autocollapse,
        ),
        PatchRule(
            name="show_reasoning_items_in_log",
            unpatched=re.compile(
                r'(?P<render>\w+)=(?P<child>\w+),(?P<item>\w+)\.type===\"reasoning\"&&\((?P=render)=null\)'
            ),
            patched=re.compile(r"(?P<render>\w+)=(?P<child>\w+)\s*\}\s*let\s+\w+;\s*\w+\[\d+\]!==\1"),
            replacement=repl_show_reasoning_items,
        ),
        PatchRule(
            name="reasoning_no_autocollapse_on_finish",
            unpatched=re.compile(
                r"if\(!(?P<stream>\w+)\)\{(?P<setter>\w+)\(!1\);return\}const (?P<el>\w+)=(?P<ref>\w+)\.current;"
            ),
            patched=re.compile(
                r"if\(!(?P<stream>\w+)\)\{return\}const (?P<el>\w+)=(?P<ref>\w+)\.current;"
            ),
            replacement=repl_no_autocollapse_reasoning,
        ),
        PatchRule(
            name="reasoning_autoscroll_user_scroll_flag",
            unpatched=re.compile(
                r"const (?P<el>\w+)=(?P<ref>\w+)\.current;(?P=el)&&\((?:(?P=el)\.scrollHeight-(?P=el)\.clientHeight-(?P=el)\.scrollTop<16\)&&\()?(?P=el)\.scrollTop=(?P=el)\.scrollHeight\)"
            ),
            patched=re.compile(r"__codexReasoningAutoScrollInit"),
            replacement=repl_autoscroll_user_scroll_flag,
        ),
    ]

    ts = dt.datetime.now(dt.UTC).strftime("%Y%m%dT%H%M%SZ")
    backup_asar = app_asar.with_suffix(app_asar.suffix + f".bak.{ts}")
    tmp_out_asar = Path(tempfile.gettempdir()) / f"codex.app.asar.patched.{ts}.asar"

    with tempfile.TemporaryDirectory(prefix="codex_app_asar_extract_") as tmpdir:
        extracted = Path(tmpdir)
        run_checked("npx", "-y", "asar", "extract", str(app_asar), str(extracted))

        bundle = find_webview_bundle_from_index_html(extracted)
        original_js = bundle.read_text("utf-8", errors="strict")

        text = original_js
        statuses: list[tuple[str, str]] = []
        for rule in patches:
            text, status = apply_rule(text, rule, dry_run=args.dry_run)
            statuses.append((rule.name, status))

        for name, status in statuses:
            print(f"{name}: {status}")

        if args.dry_run:
            return 0

        if text == original_js:
            print("No changes to write (all patches already applied).")
            return 0

        bundle.write_text(text, "utf-8")
        run_checked("node", "--check", str(bundle))

        if not args.no_beautify:
            beautified = bundle.with_suffix(".beautified.js")
            run_checked(
                "npx",
                "-y",
                "js-beautify@1.15.1",
                str(bundle),
                "-o",
                str(beautified),
                "--indent-size",
                "2",
                "--wrap-line-length",
                "100",
                "--max-preserve-newlines",
                "2",
                "--end-with-newline",
            )

        run_checked("npx", "-y", "asar", "pack", str(extracted), str(tmp_out_asar))

        backup_asar.write_bytes(app_asar.read_bytes())
        app_asar.write_bytes(tmp_out_asar.read_bytes())

        if args.keep_extracted:
            keep_dir = Path(tempfile.gettempdir()) / f"codex_app_asar_extract_keep.{ts}"
            if keep_dir.exists():
                raise RuntimeError(f"Refusing to overwrite: {keep_dir}")
            extracted.replace(keep_dir)
            print(f"kept_extracted: {keep_dir}")

    print("PATCHED")
    print(f"asar:        {app_asar}")
    print(f"backup:      {backup_asar}")
    print(f"sha256(new): {sha256_file(app_asar)}")
    print(f"sha256(bak): {sha256_file(backup_asar)}")
    print(f"asar_header_sha256: {sha256_asar_header_json(app_asar)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
