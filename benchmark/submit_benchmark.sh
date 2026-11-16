#!/bin/bash
# Submit the benchmark to c-3t (internet access): download -> db -> run,
# each job starting only if the previous one succeeded (afterok).
#
#   bash benchmark/submit_benchmark.sh            # all three
#   bash benchmark/submit_benchmark.sh db run     # a subset, in that order
#   bash benchmark/report.sh                      # results table, once the jobs have ended
#
# Overrides via env, e.g. DB_THREADS=48 bash benchmark/submit_benchmark.sh

set -euo pipefail
export REPO=$(realpath "$(dirname "$0")/..")
export RESULTS=$REPO/benchmark/results
export DB_DIR=${DB_DIR:-$REPO/db}
export CLEAN=${CLEAN:-false}                              # true: delete NCBI download after split
export PRIMER_F=${PRIMER_F:-CTTGGTCATTTAGAGGAAGTAA}       # ITS1F (README)
export PRIMER_R=${PRIMER_R:-GCTGCGTTCTTCATCGATGC}         # ITS2  (README)
mkdir -p "$RESULTS"

# stage -> "cpus mem time"  (mem = padding; memory is not billed on c-3t, only CPUs)
declare -A RES=(
  [download]="1 8G 3-00:00:00"
  [db]="${DB_THREADS:-36} 750G 7-00:00:00"
  [run]="${RUN_THREADS:-12} 250G 3-00:00:00"
)

prev=""
for stage in "${@:-download db run}"; do
  for s in $stage; do
    read -r cpus mem time <<< "${RES[$s]:?unknown stage $s}"
    prev=$(THREADS=$cpus sbatch --parsable --export=ALL -p c-3t -N1 -n1 \
      -c "$cpus" --mem="$mem" -t "$time" -J "ebm_$s" -o "$RESULTS/${s}_%j.out" \
      ${prev:+--dependency=afterok:$prev} \
      --wrap="bash $REPO/benchmark/bench_job.sh $s")
    echo "$s $prev" | tee -a "$RESULTS/jobs.txt"           # read by report.sh
  done
done
