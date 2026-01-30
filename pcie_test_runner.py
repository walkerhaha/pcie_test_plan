#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
import os
import shlex
import subprocess
import sys
from dataclasses import dataclass
from typing import List, Optional, Tuple


@dataclass
class Case:
    name: str
    cmd: List[str]


@dataclass
class CaseResult:
    name: str
    cmd: List[str]
    returncode: int
    last_line: str
    passed: bool
    stdout: str
    stderr: str


def ensure_executable(path: str) -> None:
    if not os.path.exists(path):
        raise FileNotFoundError(f"Script not found: {path}")
    if not os.access(path, os.X_OK):
        raise PermissionError(f"Script is not executable: {path} (try: chmod +x {shlex.quote(path)})")


def run_cmd(cmd: List[str], timeout_s: Optional[int]) -> Tuple[int, str, str]:
    p = subprocess.run(
        cmd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout_s,
    )
    return p.returncode, p.stdout, p.stderr


def last_nonempty_line(text: str) -> str:
    for ln in reversed(text.splitlines()):
        if ln.strip():
            return ln.strip()
    return ""


def judge_pass(returncode: int) -> bool:
    # 你已明确：上层建议只看退出码
    return returncode == 0


def build_cases(ep_bdf: str, scripts_dir: str) -> List[Case]:
    speed_script = os.path.join(scripts_dir, "pcie_speed_change_ep.sh")
    width_script = os.path.join(scripts_dir, "pcie_width_change_ep.sh")
    id_check_script = os.path.join(scripts_dir, "pcie_ep_check_id.sh")
    bar_check_script = os.path.join(scripts_dir, "pcie_ep_check_bar_size.sh")

    # ensure all required scripts exist & executable
    ensure_executable(speed_script)
    ensure_executable(width_script)
    ensure_executable(id_check_script)
    ensure_executable(bar_check_script)

    cases: List[Case] = []

    # 1) EP ID check (single)
    cases.append(
        Case(
            name="pcie_ep_check_id",
            cmd=[id_check_script, "-ep", ep_bdf],
        )
    )

    # 2) EP BAR size check (single)
    cases.append(
        Case(
            name="pcie_ep_check_bar_size",
            cmd=[bar_check_script, "-ep", ep_bdf],
        )
    )

    # 3) speed change matrix: 3,4,5
    for tg in (3, 4, 5):
        cases.append(
            Case(
                name=f"pcie_speed_change_ep tg={tg}",
                cmd=[speed_script, "-ep", ep_bdf, "-tg", str(tg)],
            )
        )

    # 4) width change matrix: x1,x2,x4,x8
    for tw in ("x1", "x2", "x4", "x8"):
        cases.append(
            Case(
                name=f"pcie_width_change_ep tw={tw}",
                cmd=[width_script, "-ep", ep_bdf, "-tw", tw],
            )
        )

    return cases


def main() -> int:
    parser = argparse.ArgumentParser(description="PCIe top-level runner (explicit cases only).")
    parser.add_argument("-ep", "--ep-bdf", required=True, help="EP BDF, e.g. 18:00.0 or 0000:18:00.0")
    parser.add_argument("--scripts-dir", default="./test_scripts", help="Directory containing scripts (default: ./test_scripts)")
    parser.add_argument("--timeout", type=int, default=180, help="Timeout seconds per case (default: 180)")
    args = parser.parse_args()

    try:
        cases = build_cases(args.ep_bdf, args.scripts_dir)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    print(f"EP          : {args.ep_bdf}")
    print(f"Scripts dir : {os.path.abspath(args.scripts_dir)}")
    print(f"Total cases : {len(cases)}")
    print("-" * 88)

    results: List[CaseResult] = []
    overall_pass = True

    for idx, c in enumerate(cases, 1):
        cmd_str = " ".join(shlex.quote(x) for x in c.cmd)
        print(f"[{idx}/{len(cases)}] RUN  : {c.name}")
        print(f"          CMD  : {cmd_str}")

        try:
            rc, out, err = run_cmd(c.cmd, timeout_s=args.timeout)
        except subprocess.TimeoutExpired as e:
            # 如果你希望 timeout 也算 FAIL，用非 0 即可；这里用 124 便于区分
            rc = 124
            out = e.stdout or ""
            err = (e.stderr or "") + f"\n[TIMEOUT] exceeded {args.timeout}s"
        except Exception as e:
            rc = 125
            out = ""
            err = f"[EXCEPTION] {type(e).__name__}: {e}"

        ll = last_nonempty_line(out)
        passed = judge_pass(rc)

        results.append(
            CaseResult(
                name=c.name,
                cmd=c.cmd,
                returncode=rc,
                last_line=ll,
                passed=passed,
                stdout=out,
                stderr=err,
            )
        )

        status = "PASS" if passed else "FAIL"
        print(f"          RC   : {rc}")
        print(f"          LAST : {ll}")
        if err.strip():
            print(f"          STDERR:\n{err.rstrip()}")
        print(f"          RES  : {status}")
        print("-" * 88)

        if not passed:
            overall_pass = False

    print("\nSUMMARY")
    print("=" * 88)
    for r in results:
        status = "PASS" if r.passed else "FAIL"
        cmd_str = " ".join(shlex.quote(x) for x in r.cmd)
        print(f"{status:4} | {r.name:30} | rc={r.returncode:3} | {cmd_str}")
    print("=" * 88)
    print(f"OVERALL: {'PASS' if overall_pass else 'FAIL'}")

    return 0 if overall_pass else 1


if __name__ == "__main__":
    sys.exit(main())
