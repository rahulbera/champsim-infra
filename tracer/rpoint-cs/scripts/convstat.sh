#!/bin/bash
# Count every stage of the conversion pipeline, not just raw2champsim.
# A window sitting in trace_sanity_check has ZERO raw2champsim processes and is
# perfectly healthy -- counting only the converter reports "0 converters while
# windows incomplete", which is an ESCALATE condition, from a working system.
f=0; c=0; s=0
for p in $(pgrep -u "$(id -un)" . 2>/dev/null); do
  case "$(readlink /proc/$p/exe 2>/dev/null)" in
    *trace_filter)       f=$((f+1)) ;;
    *raw2champsim)       c=$((c+1)) ;;
    *trace_sanity_check) s=$((s+1)) ;;
  esac
done
echo "filter=$f convert=$c sanity=$s pipeline_total=$((f+c+s))"
