#!/usr/bin/env python3

import argparse
import csv
import os
import re
import sys
import yaml
from concurrent.futures import ProcessPoolExecutor, as_completed


# Keywords (case-insensitive) that mark a simulation as failed when present in
# the .err file. Refine this list as more failure modes are observed.
FAILURE_KEYWORDS = [
    "segmentation fault",
    "aborted",
    "terminate called",
    "assertion failed",
    "killed",
    "core dumped",
    "bad_alloc",
    "fatal error",
    "std::exception",
    "stack smashing detected",
]

FAILURE_PATTERN = re.compile(
    "|".join(re.escape(k) for k in FAILURE_KEYWORDS), re.IGNORECASE
)

VAR_PATTERN = re.compile(r"\$\(([^)]+)\)")


class Trace:
    def __init__(self, name):
        self.name = name


class Experiment:
    def __init__(self, name, params):
        self.name = name
        self.params = params


def load_yaml(file_path):
    with open(file_path, "r") as f:
        return yaml.safe_load(f)


def replace_variables(value, definitions):
    if not isinstance(value, str):
        return value
    for match in VAR_PATTERN.findall(value):
        if match not in definitions:
            sys.exit(f"Encountered undefined variable: {match}")
        value = value.replace(f"$({match})", definitions[match])
    return value


def _record(store, key, value, source, kind):
    """Insert key→value into store; abort if it conflicts with a prior source."""
    if key in store:
        prev_value, prev_source = store[key]
        if prev_value != value:
            sys.exit(
                f"Conflict: {kind} '{key}' has different definitions in "
                f"'{prev_source}' and '{source}'"
            )
        return False
    store[key] = (value, source)
    return True


def create_traces(paths):
    """Merge trace YAMLs by trace name. Order = first-seen across files."""
    store = {}
    for path in paths:
        data = load_yaml(path) or {}
        for _suite, entries in data.items():
            for entry in entries or []:
                for name, info in entry.items():
                    _record(store, name, info, path, "trace")
    return [Trace(n) for n in store]


def create_experiments(paths):
    """Merge experiment YAMLs (definitions + experiments) by name."""
    def_store = {}
    exp_store = {}
    for path in paths:
        data = load_yaml(path) or {}
        for d in data.get("definitions", []) or []:
            for k, v in d.items():
                _record(def_store, k, v, path, "definition")
        for entry in data.get("experiments", []) or []:
            for name, raw in entry.items():
                _record(exp_store, name, raw, path, "experiment")

    definitions = {k: v for k, (v, _) in def_store.items()}
    experiments = []
    for name, (raw, _) in exp_store.items():
        params = raw.get("params", "") if isinstance(raw, dict) else raw
        params = replace_variables(params, definitions)
        experiments.append(Experiment(name, params))
    return experiments


def parse_metric_definitions(paths):
    """Merge metric YAMLs by metric name. Order = first-seen across files."""
    store = {}
    for path in paths:
        data = load_yaml(path) or []
        for entry in data:
            for name, expr in entry.items():
                expr_str = str(expr)
                _record(store, str(name).strip(), expr_str, path, "metric")
    metrics = []
    for name, (expr_str, _) in store.items():
        keys = VAR_PATTERN.findall(expr_str)
        metrics.append((name, expr_str, keys))
    return metrics


def check_failure(err_path):
    """True if err is missing, or contains a failure keyword. Empty err => pass."""
    try:
        size = os.path.getsize(err_path)
    except OSError:
        return True
    if size == 0:
        return False
    try:
        with open(err_path, "r", errors="replace") as f:
            content = f.read()
    except OSError:
        return True
    return bool(FAILURE_PATTERN.search(content))


def extract_stats_from_out(out_path, required_stats):
    """Stream the out file once and pull only the stats we need.

    Each interesting line is "<stat name><whitespace><value>". Stops as soon
    as every required stat has been captured.
    """
    found = {}
    if not required_stats:
        return found
    remaining = set(required_stats)
    try:
        with open(out_path, "r", errors="replace") as f:
            for line in f:
                if not remaining:
                    break
                parts = line.split(None, 1)
                if len(parts) != 2:
                    continue
                key = parts[0]
                if key in remaining:
                    val_token = parts[1].split(None, 1)[0]
                    try:
                        found[key] = float(val_token)
                        remaining.discard(key)
                    except ValueError:
                        pass
    except OSError:
        pass
    return found


_EVAL_GLOBALS = {
    "__builtins__": {},
    "abs": abs,
    "min": min,
    "max": max,
    "round": round,
}


def evaluate_metric(expr, stats):
    """Substitute $(name) tokens with extracted values and evaluate."""
    keys = VAR_PATTERN.findall(expr)
    for k in keys:
        if k not in stats:
            return None
        expr = expr.replace(f"$({k})", repr(stats[k]))
    try:
        result = eval(expr, _EVAL_GLOBALS)
    except ZeroDivisionError:
        return float("inf")
    except Exception:
        return None
    if isinstance(result, float):
        return round(result, 6)
    return result


def process_trace(trace_name, exp_names, metrics, stats_dir):
    """Process every experiment for one trace. Returns list of CSV rows."""
    rows = []
    required = set()
    for _, _, keys in metrics:
        required.update(keys)

    trace_failed = False
    for exp_name in exp_names:
        base = os.path.join(stats_dir, f"{trace_name}_{exp_name}")
        out_path = base + ".out"
        err_path = base + ".err"

        out_exists = os.path.isfile(out_path)
        err_exists = os.path.isfile(err_path)

        if not out_exists or not err_exists or check_failure(err_path):
            trace_failed = True
            rows.append([trace_name, exp_name] + ["" for _ in metrics] + [0])
            continue

        stats = extract_stats_from_out(out_path, required)
        values = []
        for _name, expr, _keys in metrics:
            v = evaluate_metric(expr, stats)
            values.append("" if v is None else v)
        rows.append([trace_name, exp_name] + values + [1])

    if trace_failed:
        for row in rows:
            row[-1] = 0
    return rows


def main():
    parser = argparse.ArgumentParser(
        description="Roll up ChampSim per-(trace,exp) stats into a single CSV."
    )
    parser.add_argument(
        "--mfile",
        required=True,
        nargs="+",
        help="One or more metrics YAML files (merged; conflicting names abort)",
    )
    parser.add_argument(
        "--tlist",
        required=True,
        nargs="+",
        help="One or more trace YAML files (merged; conflicting names abort)",
    )
    parser.add_argument(
        "--exp",
        required=True,
        nargs="+",
        help="One or more experiment YAML files (merged; conflicting names abort)",
    )
    parser.add_argument(
        "-d",
        "--stats-dir",
        required=True,
        help="Directory containing the {trace}_{exp}.out and .err files",
    )
    parser.add_argument(
        "--threads",
        type=int,
        default=os.cpu_count() or 1,
        help="Number of worker processes (default: cpu_count)",
    )
    parser.add_argument(
        "-o", "--output", default="stats.csv", help="Output CSV filename"
    )
    args = parser.parse_args()

    if not os.path.isdir(args.stats_dir):
        sys.exit(f"Stats directory does not exist: {args.stats_dir}")

    traces = create_traces(args.tlist)
    experiments = create_experiments(args.exp)
    metrics = parse_metric_definitions(args.mfile)

    metric_names = [m[0] for m in metrics]
    exp_names = [e.name for e in experiments]

    results: list[list[list]] = [[] for _ in traces]
    workers = max(1, min(args.threads, len(traces)))

    with ProcessPoolExecutor(max_workers=workers) as pool:
        futures = {
            pool.submit(
                process_trace, trace.name, exp_names, metrics, args.stats_dir
            ): i
            for i, trace in enumerate(traces)
        }
        for fut in as_completed(futures):
            results[futures[fut]] = fut.result()

    with open(args.output, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["TraceName", "ExpName"] + metric_names + ["Filter"])
        for trace_rows in results:
            writer.writerows(trace_rows)

    total = sum(len(r) for r in results)
    passed = sum(1 for r in results for row in r if row[-1] == 1)
    print(
        f"Wrote {total} rows ({passed} passed, {total - passed} filtered) "
        f"to '{args.output}'"
    )


if __name__ == "__main__":
    main()
