#!/usr/bin/env python3
"""Differential corpus harness: generate random-but-valid POSIX shell scripts,
run them under rush and reference shells, and report divergences.

Complements test/corpus (hand-curated, exact-match) with seeded generation.
A finding is reported when:
  - rush crashes (exits by signal) on input every reference completes, or
  - rush hangs (timeout) while every reference completes, or
  - all references agree on (status, stdout) and rush disagrees.
Reference disagreement means the behavior is effectively unspecified; the case
is skipped. stderr is never compared (diagnostic wording differs per shell).

Usage:
  scripts/diffharness.py show --seed 42
  scripts/diffharness.py run --start-seed 0 --count 500 [--rush zig-out/bin/rush]
  scripts/diffharness.py run --count 500 --findings-dir /tmp/findings

Findings are minimized (statement-level delta debugging) and written one
directory per fingerprint: script.sh, fixtures listing, report.txt.
Known/filed bugs can be suppressed via an allowlist file of fingerprints
(--allowlist, default scripts/diffharness-allowlist.txt; '#' comments).
"""

import argparse
import hashlib
import os
import random
import resource
import shutil
import signal
import subprocess
import sys
import tempfile
import time

# ---------------------------------------------------------------------------
# Case model

FIXTURE_SPECS = {
    "f1": ("file", "alpha\nbravo\ncharlie\n"),
    "f2": ("file", "one two\nthree\n"),
    "e1": ("file", ""),
    "d1": ("dir", None),
    "d1/g1": ("file", "nested\n"),
    "l1": ("symlink", "d1"),
    "ro1": ("rofile", "readonly\n"),
}

STDIN_DATA = "sin-one\nsin-two\nsin-three\n"


class Case:
    def __init__(self, seed, script, uses_stdin, uses_fifo):
        self.seed = seed
        self.script = script
        self.uses_stdin = uses_stdin
        self.uses_fifo = uses_fifo


# ---------------------------------------------------------------------------
# Generator

VAR_POOL = ["v1", "v2", "v3"]
FN_POOL = ["fn1", "fn2"]
WORDS = ["foo", "bar", "baz-1", "two words", "a*b", "-n-ish", ""]


class Gen:
    def __init__(self, seed):
        self.rng = random.Random(seed)
        self.seed = seed
        self.vars = set()
        self.funcs = set()
        self.fds = set()  # fds opened via exec n>...
        self.loop_depth = 0
        self.uses_stdin = False
        self.uses_fifo = False

    # -- small pieces ------------------------------------------------------

    def word(self, allow_expand=True):
        r = self.rng.random()
        if allow_expand and self.vars and r < 0.25:
            v = self.rng.choice(sorted(self.vars))
            return self.rng.choice(['"$%s"' % v, "$%s" % v, '"x${%s}y"' % v])
        if allow_expand and r < 0.33:
            return '"$(%s)"' % self.producer()
        w = self.rng.choice(WORDS)
        if any(c in w for c in " *?") or w == "":
            return "'%s'" % w if self.rng.random() < 0.5 else '"%s"' % w
        return w

    def infile(self):
        return self.rng.choice(["f1", "f2", "e1", "d1/g1"])

    def outfile(self):
        return self.rng.choice(["out1", "out2", "d1/out3"])

    def producer(self):
        r = self.rng.random()
        if r < 0.5:
            return "echo %s" % self.word()
        if r < 0.75:
            return "printf '%%s\\n' %s" % self.word()
        return "cat %s" % self.infile()

    def filter_cmd(self):
        return self.rng.choice(
            ["tr a-z A-Z", "sort", "head -n 1", "wc -c", "cat"]
        )

    def consumer(self):
        r = self.rng.random()
        if r < 0.3 and self.rng.random() < 0.5:
            v = self.rng.choice(VAR_POOL)
            self.vars.add(v)
            return "read %s" % v
        return self.filter_cmd()

    def status_cmd(self):
        r = self.rng.random()
        if r < 0.3:
            return self.rng.choice(["true", "false"])
        if r < 0.6:
            return "test %s = %s" % (self.word(), self.word())
        if r < 0.8:
            return "[ -f %s ]" % self.infile()
        return "[ -d d1 ]"

    def redirection(self, for_output=True):
        r = self.rng.random()
        if for_output:
            if r < 0.5:
                return "> %s" % self.outfile()
            if r < 0.7:
                return ">> %s" % self.outfile()
            if r < 0.85:
                return "2> %s" % self.outfile()
            return "> %s 2>&1" % self.outfile()
        return "< %s" % self.infile()

    # -- statements --------------------------------------------------------

    def simple(self):
        parts = [self.producer()]
        if self.rng.random() < 0.4:
            parts.append(self.redirection(for_output=True))
        return " ".join(parts)

    def pipeline(self, depth):
        stages = [self.producer()]
        for _ in range(self.rng.randint(1, 3)):
            if depth < 2 and self.rng.random() < 0.3:
                stages.append("{ %s; %s; }" % (self.consumer(), self.producer()))
            else:
                stages.append(self.filter_cmd())
        return " | ".join(stages)

    def and_or(self, depth):
        op = self.rng.choice(["&&", "||"])
        return "%s %s %s" % (self.status_cmd(), op, self.statement(depth + 1))

    def if_stmt(self, depth):
        cond = self.status_cmd()
        body = self.statement(depth + 1)
        if self.rng.random() < 0.5:
            return "if %s; then %s; else %s; fi" % (
                cond, body, self.statement(depth + 1))
        return "if %s; then %s; fi" % (cond, body)

    def for_loop(self, depth):
        v = self.rng.choice(VAR_POOL)
        self.vars.add(v)
        items = " ".join(self.word(allow_expand=False) for _ in range(self.rng.randint(1, 3)))
        self.loop_depth += 1
        body = self.statement(depth + 1)
        if self.loop_depth <= 2 and self.rng.random() < 0.2:
            body += "; " + self.rng.choice(["break", "continue"])
        self.loop_depth -= 1
        out = "for %s in %s; do %s; done" % (v, items, body)
        if self.rng.random() < 0.25:
            out += " %s" % self.redirection(for_output=True)
        return out

    def while_loop(self, depth):
        v = self.rng.choice(VAR_POOL)
        self.vars.add(v)
        self.loop_depth += 1
        body = self.statement(depth + 1)
        self.loop_depth -= 1
        return ("%s=0; while [ $%s -lt %d ]; do %s=$((%s+1)); %s; done"
                % (v, v, self.rng.randint(1, 3), v, v, body))

    def case_stmt(self, depth):
        subj = self.word()
        pat = self.rng.choice(["foo", "f*", "*o", "two*", "?ar", "*"])
        return "case %s in %s) %s;; *) %s;; esac" % (
            subj, pat, self.statement(depth + 1), self.statement(depth + 1))

    def subshell(self, depth):
        inner = "; ".join(self.statement(depth + 1)
                          for _ in range(self.rng.randint(1, 2)))
        grp = "(%s)" % inner if self.rng.random() < 0.5 else "{ %s; }" % inner
        if self.rng.random() < 0.4:
            grp += " %s" % self.redirection(for_output=True)
        return grp

    def func(self, depth):
        name = self.rng.choice(FN_POOL)
        self.funcs.add(name)
        body = self.statement(depth + 1)
        if self.rng.random() < 0.3:
            body += "; return %d" % self.rng.randint(0, 3)
        define = "%s() { %s; }" % (name, body)
        call = "%s %s" % (name, self.word()) if self.rng.random() < 0.5 else name
        return "%s; %s; echo fn=$?" % (define, call)

    def assignment(self):
        v = self.rng.choice(VAR_POOL)
        self.vars.add(v)
        r = self.rng.random()
        if r < 0.4:
            return "%s=%s" % (v, self.word())
        if r < 0.7:
            return "%s=$(%s)" % (v, self.producer())
        if r < 0.85:
            return "%s=%s; unset %s" % (v, self.word(), v)
        return "%s=%s; export %s" % (v, self.word(), v)

    def param_expand(self):
        v = self.rng.choice(sorted(self.vars)) if self.vars else "novar"
        form = self.rng.choice(
            ["${%s:-dflt}", "${%s:=dflt}", "${%s:+alt}", "${#%s}",
             "${%s#f*}", "${%s%%%%o}"]
        )
        return "echo %s" % (form % v)

    def heredoc(self):
        v = self.rng.choice(sorted(self.vars)) if self.vars else "novar"
        quote = self.rng.random() < 0.3
        delim = "'EOF'" if quote else "EOF"
        return "%s <<%s\nline $%s\nsecond\nEOF" % (self.consumer(), delim, v)

    # -- scenario templates (stateful shapes random composition rarely hits)

    def tmpl_exec_fd(self, depth):
        fd = self.rng.choice([3, 4, 5])
        self.fds.add(fd)
        mid = self.statement(depth + 1)
        return ("exec %d> %s; echo via%d >&%d; %s; exec %d>&-; cat %s"
                % (fd, self.outfile(), fd, fd, mid, fd, self.outfile()))

    def tmpl_fifo(self, depth):
        self.uses_fifo = True
        return "echo fifo-data > p1 & cat < p1; wait"

    def tmpl_bg_wait(self, depth):
        r = self.rng.random()
        if r < 0.4:
            return "%s & wait $!; echo bg=$?" % self.simple()
        if r < 0.7:
            return "(exit %d) & wait $!; echo bg=$?" % self.rng.randint(0, 4)
        return "sleep 0.1 & kill $! 2>/dev/null; wait $!; echo bg=$?"

    def tmpl_trap(self, depth):
        sig = self.rng.choice(["TERM", "USR1", "INT"])
        return ('trap "echo trapped-%s" %s; kill -%s $$; echo after'
                % (sig, sig, sig, sig)).replace("%s", sig)  # never reached

    def tmpl_trap_safe(self, depth):
        sig = self.rng.choice(["TERM", "USR1"])
        body = self.rng.choice(["echo trapped", "true"])
        sender = self.rng.choice(["kill -%s $$" % sig, "(kill -%s $$)" % sig])
        return 'trap "%s" %s; %s; echo after=$?' % (body, sig, sender)

    def tmpl_exit_trap(self, depth):
        return 'trap "echo at-exit" EXIT; %s' % self.statement(depth + 1)

    def tmpl_cd(self, depth):
        seq = self.rng.choice([
            "cd d1; pwd; cd ..; pwd",
            "cd l1; pwd; cd ..; pwd",
            "(cd d1; pwd); pwd",
            "CDPATH=.; cd d1 >/dev/null 2>&1; pwd",
        ])
        return "%s | sed s,$PWD0,SANDBOX," % ("{ %s; }" % seq)

    def tmpl_set_e(self, depth):
        return "set -e; %s || echo caught; echo alive" % self.status_cmd()

    def tmpl_dot(self, depth):
        body = self.statement(depth + 1).replace("'", "'\\''")
        return "printf '%%s\\n' '%s' > src1.sh; . ./src1.sh; echo dot=$?" % body

    def tmpl_eval(self, depth):
        inner = self.statement(depth + 1).replace("\\", "\\\\").replace('"', '\\"')
        if "\n" in inner:
            inner = "echo evalfallback"
        return 'eval "%s"' % inner

    def tmpl_stdin(self, depth):
        self.uses_stdin = True
        return self.rng.choice([
            "head -n 1; cat",
            "read v1; echo got=$v1; cat",
            "cat; echo done",
        ])

    # -- dispatch -----------------------------------------------------------

    def statement(self, depth=0):
        if depth >= 3:
            return self.simple()
        productions = [
            (10, self.simple),
            (8, lambda: self.pipeline(depth)),
            (6, self.assignment),
            (4, lambda: self.if_stmt(depth)),
            (4, lambda: self.and_or(depth)),
            (3, lambda: self.for_loop(depth)),
            (2, lambda: self.while_loop(depth)),
            (3, lambda: self.case_stmt(depth)),
            (4, lambda: self.subshell(depth)),
            (3, lambda: self.func(depth)),
            (3, self.param_expand),
            (2, self.status_cmd),
        ]
        if depth == 0:
            # here-docs only at statement level: nested inside `;;`/`done`/`fi`
            # joins, the closing EOF line would not stand alone
            productions.append((2, self.heredoc))
        if depth == 0:
            productions += [
                (2, lambda: self.tmpl_exec_fd(depth)),
                (2, lambda: self.tmpl_bg_wait(depth)),
                (2, lambda: self.tmpl_trap_safe(depth)),
                (1, lambda: self.tmpl_exit_trap(depth)),
                (2, lambda: self.tmpl_cd(depth)),
                (2, lambda: self.tmpl_set_e(depth)),
                (2, lambda: self.tmpl_dot(depth)),
                (2, lambda: self.tmpl_eval(depth)),
                (1, lambda: self.tmpl_fifo(depth)),
                (1, lambda: self.tmpl_stdin(depth)),
            ]
        total = sum(w for w, _ in productions)
        pick = self.rng.uniform(0, total)
        acc = 0
        for w, fn in productions:
            acc += w
            if pick <= acc:
                return fn()
        return self.simple()

    def generate(self):
        n = self.rng.randint(1, 5)
        stmts = [self.statement(0) for _ in range(n)]
        stmts.append("echo final=$?")
        script = "\n".join(stmts) + "\n"
        return Case(self.seed, script, self.uses_stdin, self.uses_fifo)


def generate_case(seed):
    return Gen(seed).generate()


# ---------------------------------------------------------------------------
# Execution

TIMEOUT_S = 5


def make_sandbox(case):
    root = tempfile.mkdtemp(prefix="diffharness-")
    for rel, (kind, content) in FIXTURE_SPECS.items():
        path = os.path.join(root, rel)
        if kind == "dir":
            os.makedirs(path, exist_ok=True)
        elif kind in ("file", "rofile"):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(content)
            if kind == "rofile":
                os.chmod(path, 0o444)
    if case.uses_fifo:
        os.mkfifo(os.path.join(root, "p1"))
    return root


def child_limits():
    resource.setrlimit(resource.RLIMIT_CPU, (3, 3))
    resource.setrlimit(resource.RLIMIT_FSIZE, (8 << 20, 8 << 20))
    resource.setrlimit(resource.RLIMIT_NOFILE, (256, 256))
    # No RLIMIT_NPROC: on macOS it is per-UID, so a low cap starves every
    # process of this user (and trips fork-failure paths in all shells).
    # Fork bombs are bounded by RLIMIT_CPU plus the timeout's killpg.


def run_shell(argv, case, sandbox):
    env = {
        "PATH": "/bin:/usr/bin",
        "HOME": sandbox,
        "LC_ALL": "C",
        "TERM": "dumb",
        # physical path: `pwd` output is physical and sandboxes often live
        # behind symlinks (/tmp, /var on macOS)
        "PWD0": os.path.realpath(sandbox),
    }
    script_path = os.path.join(sandbox, ".script.sh")
    with open(script_path, "w") as f:
        f.write(case.script)
    stdin_data = STDIN_DATA if case.uses_stdin else ""
    try:
        proc = subprocess.Popen(
            argv + [script_path],
            cwd=sandbox,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
            preexec_fn=child_limits,
        )
    except OSError as e:
        return {"status": "spawn-error", "rc": None, "out": b"", "err": str(e).encode()}
    try:
        out, err = proc.communicate(stdin_data.encode(), timeout=TIMEOUT_S)
        rc = proc.returncode
        kind = "signal" if rc < 0 else "exit"
        return {"status": kind, "rc": rc, "out": out, "err": err}
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.wait()
        return {"status": "timeout", "rc": None, "out": b"", "err": b""}
    finally:
        # reap any stragglers in the group
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass


def run_case(case, rush, refs):
    """Returns (verdict, detail). verdict in:
    crash | hang | divergence | ok | unspecified | flaky-refs"""
    results = {}
    for name, argv in [("rush", rush)] + refs:
        sandbox = make_sandbox(case)
        try:
            results[name] = run_shell(argv, case, sandbox)
        finally:
            shutil.rmtree(sandbox, ignore_errors=True)

    r = results["rush"]
    ref_results = [(n, results[n]) for n, _ in refs]
    refs_completed = all(v["status"] == "exit" for _, v in ref_results)

    if r["status"] == "signal" and refs_completed:
        return "crash", results
    if r["status"] == "timeout" and refs_completed:
        return "hang", results
    if not refs_completed:
        return "flaky-refs", results
    if r["status"] != "exit":
        return "flaky-refs", results

    keys = [(v["rc"], v["out"]) for _, v in ref_results]
    if any(k != keys[0] for k in keys[1:]):
        return "unspecified", results
    if (r["rc"], r["out"]) != keys[0]:
        return "divergence", results
    return "ok", results


# ---------------------------------------------------------------------------
# Shrinking

def split_statements(script):
    # statement granularity = lines; heredocs keep their block intact
    lines = script.split("\n")
    blocks, cur, in_heredoc = [], [], False
    for line in lines:
        cur.append(line)
        if in_heredoc:
            if line.strip() == "EOF":
                blocks.append("\n".join(cur))
                cur, in_heredoc = [], False
            continue
        if "<<EOF" in line or "<<'EOF'" in line:
            in_heredoc = True
            continue
        blocks.append("\n".join(cur))
        cur = []
    if cur:
        blocks.append("\n".join(cur))
    return [b for b in blocks if b.strip()]


def shrink(case, verdict, rush, refs):
    blocks = split_statements(case.script)

    def still_fails(candidate_blocks):
        if not candidate_blocks:
            return False
        c = Case(case.seed, "\n".join(candidate_blocks) + "\n",
                 case.uses_stdin, case.uses_fifo)
        v, _ = run_case(c, rush, refs)
        return v == verdict

    changed = True
    while changed:
        changed = False
        i = 0
        while i < len(blocks):
            candidate = blocks[:i] + blocks[i + 1:]
            if still_fails(candidate):
                blocks = candidate
                changed = True
            else:
                i += 1
    return Case(case.seed, "\n".join(blocks) + "\n",
                case.uses_stdin, case.uses_fifo)


# ---------------------------------------------------------------------------
# Reporting

def fingerprint(verdict, script):
    norm = " ".join(script.split())
    return hashlib.sha256(("%s|%s" % (verdict, norm)).encode()).hexdigest()[:16]


def write_finding(dirpath, case, verdict, results):
    os.makedirs(dirpath, exist_ok=True)
    with open(os.path.join(dirpath, "script.sh"), "w") as f:
        f.write(case.script)
    with open(os.path.join(dirpath, "report.txt"), "w") as f:
        f.write("verdict: %s\nseed: %d\nuses_stdin: %s\nuses_fifo: %s\n\n"
                % (verdict, case.seed, case.uses_stdin, case.uses_fifo))
        f.write("script:\n%s\n" % case.script)
        for name, v in results.items():
            f.write("--- %s: status=%s rc=%s\nstdout: %r\nstderr: %r\n"
                    % (name, v["status"], v["rc"], v["out"][:500], v["err"][:500]))


def detect_refs():
    refs = []
    if shutil.which("dash"):
        refs.append(("dash", ["dash"]))
    if shutil.which("bash"):
        refs.append(("bash-posix", ["bash", "--posix"]))
    if shutil.which("yash"):
        refs.append(("yash", ["yash"]))
    return refs


def load_allowlist(path):
    """Entries are either a 16-hex fingerprint or `match:<substring>` tested
    against the minimized script normalized to one line. Substring entries
    survive re-minimization across seeds; fingerprints pin exact scripts."""
    fps, subs = set(), []
    if path and os.path.exists(path):
        with open(path) as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if not line:
                    continue
                if line.startswith("match:"):
                    subs.append(line[len("match:"):].strip())
                else:
                    fps.add(line.split()[0])
    return fps, subs


def allowlisted(allow, fp, script):
    fps, subs = allow
    if fp in fps:
        return True
    norm = " ".join(script.split())
    return any(s in norm for s in subs)


# ---------------------------------------------------------------------------
# CLI

def cmd_show(args):
    case = generate_case(args.seed)
    print("# seed=%d uses_stdin=%s uses_fifo=%s"
          % (case.seed, case.uses_stdin, case.uses_fifo))
    print(case.script, end="")


def cmd_run(args):
    rush = [os.path.abspath(args.rush)]
    refs = detect_refs()[:args.max_refs]
    if len(refs) < 2:
        print("need >=2 reference shells, found %d" % len(refs), file=sys.stderr)
        return 2
    allow = load_allowlist(args.allowlist)
    print("references: %s" % ", ".join(n for n, _ in refs))

    counts = {}
    findings = 0
    t0 = time.time()
    for seed in range(args.start_seed, args.start_seed + args.count):
        case = generate_case(seed)
        verdict, results = run_case(case, rush, refs)
        counts[verdict] = counts.get(verdict, 0) + 1
        if verdict in ("crash", "hang", "divergence"):
            small = shrink(case, verdict, rush, refs)
            v2, results2 = run_case(small, rush, refs)
            if v2 == verdict:
                case, results = small, results2
            fp = fingerprint(verdict, case.script)
            if allowlisted(allow, fp, case.script):
                counts["allowlisted"] = counts.get("allowlisted", 0) + 1
                continue
            findings += 1
            dirpath = os.path.join(args.findings_dir, "%s-%s" % (verdict, fp))
            if not os.path.exists(dirpath):
                write_finding(dirpath, case, verdict, results)
                print("NEW %s %s seed=%d -> %s" % (verdict, fp, seed, dirpath))
                print("    %s" % " ".join(case.script.split())[:120])
        if args.progress and (seed - args.start_seed + 1) % 50 == 0:
            print("  ... %d cases, %.1fs, %s"
                  % (seed - args.start_seed + 1, time.time() - t0, counts))
    print("done: %d cases in %.1fs -> %s" % (args.count, time.time() - t0, counts))
    return 1 if findings else 0


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    ps = sub.add_parser("show", help="print one generated case")
    ps.add_argument("--seed", type=int, required=True)
    ps.set_defaults(fn=cmd_show)

    pr = sub.add_parser("run", help="generate, execute, diff, shrink")
    pr.add_argument("--rush", default="zig-out/bin/rush")
    pr.add_argument("--start-seed", type=int, default=0)
    pr.add_argument("--count", type=int, default=200)
    pr.add_argument("--findings-dir", default="/tmp/diffharness-findings")
    pr.add_argument("--allowlist", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "diffharness-allowlist.txt"))
    pr.add_argument("--max-refs", type=int, default=2)
    pr.add_argument("--progress", action="store_true")
    pr.set_defaults(fn=cmd_run)

    args = p.parse_args()
    return args.fn(args) or 0


if __name__ == "__main__":
    sys.exit(main())
