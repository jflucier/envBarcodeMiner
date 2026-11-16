#!/bin/bash
# Results table from Slurm accounting (sacct) + the du files written by bench_job.sh.
# Uses the last job id recorded for each stage in results/jobs.txt.

RESULTS=$(realpath "$(dirname "$0")")/results

printf '%-9s %-10s %-11s %8s %10s %9s %8s %s\n' stage jobid state wall_h cpu_h_used cpu_h_alloc peak_GB disk
for stage in download db run; do
  jid=$(awk -v s=$stage '$1==s{j=$2} END{print j}' "$RESULTS/jobs.txt" 2>/dev/null)
  [[ -z $jid ]] && continue
  disk=$(cut -f1 "$RESULTS/$stage.du" 2>/dev/null || echo -)
  # allocation line: wall, total CPU, cpus, state; batch step: MaxRSS (summed over the job's processes)
  sacct -j "$jid" -P -n --format=JobID,Elapsed,TotalCPU,AllocCPUS,MaxRSS,State | awk -F'|' \
    -v stage=$stage -v jid=$jid -v disk="$disk" '
    function sec(t,   d, n, a) {             # [D-][HH:]MM:SS[.mmm] -> seconds
      d = 0; if (t ~ /-/) { split(t, a, "-"); d = a[1]; t = a[2] }
      n = split(t, a, ":"); return d*86400 + (n==3 ? a[1]*3600 + a[2]*60 + a[3] : a[1]*60 + a[2])
    }
    $1 == jid     { wall = sec($2); cpu = sec($3); ncpu = $4; state = $6 }
    $1 ~ /\.batch$/ { u = substr($5, length($5)); gb = $5 / (u=="K" ? 2^20 : u=="M" ? 2^10 : u=="G" ? 1 : 2^30) }
    END { printf "%-9s %-10s %-11s %8.1f %10.1f %9.1f %8.1f %s\n",
          stage, jid, state, wall/3600, cpu/3600, wall*ncpu/3600, gb, disk }'
done
