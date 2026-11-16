#!/bin/bash
# One benchmark stage (download | db | run). Submitted by submit_benchmark.sh.
# Time, CPU and memory come from Slurm accounting (see report.sh); this script only adds
# disk usage with one `du` at the end.

set -euo pipefail
MODE=$1
: "${REPO:?}" "${DB_DIR:?}" "${RESULTS:?}"

module load StdEnv/2023 apptainer/1.3.5
SIF=$REPO/containers/envBarcodeMiner.sif
OUT_DIR=$RESULTS/run_out
mkdir -p "$DB_DIR" "$OUT_DIR"
export APPTAINER_BIND="$DB_DIR,$OUT_DIR"     # repo scripts only bind the repo dir / CWD

case $MODE in
  download)
    # same files + skip checks as install_db.sh, so the db stage skips the downloads
    mkdir -p "$DB_DIR/taxonomy" && cd "$DB_DIR/taxonomy"
    [ -e taxdump.tar.gz ] || { wget -nv -O taxdump.tar.gz ftp://ftp.ncbi.nih.gov/pub/taxonomy/taxdump.tar.gz && tar -zxf taxdump.tar.gz; }
    for f in nucl_gb.accession2taxid nucl_wgs.accession2taxid.EXTRA nucl_wgs.accession2taxid; do
      [ -e "$f" ] || { wget -nv -O "$f.gz" "https://ftp.ncbi.nih.gov/pub/taxonomy/accession2taxid/$f.gz" && gunzip "$f.gz"; }
    done
    # core_nt (single thread)
    mkdir -p "$DB_DIR/NCBI" && cd "$REPO"
    singularity exec -e -B "$REPO:$REPO" "$SIF" python3 download_envBarcodeMiner_db.py "$DB_DIR/NCBI"
    # downloader exits 0 even on errors -> fail here if the BLAST db is incomplete
    singularity exec -e "$SIF" blastdbcmd -db "$DB_DIR/NCBI/core_nt" -info
    du -sh "$DB_DIR" > "$RESULTS/download.du"
    ;;
  db)
    # sqlite taxonomy + blastdbcmd (1 thread), seqkit split + dicey index (THREADS)
    bash "$REPO/install_db.sh" -db "$DB_DIR" -t "$THREADS" -c "$CLEAN"
    du -sh "$DB_DIR" > "$RESULTS/db.du"
    ;;
  run)
    # one primer pair; CWD must be the output dir (container reads primers.fa through it)
    cd "$OUT_DIR"
    bash "$REPO/run_envBarcodeMiner.local.sh" -db "$DB_DIR" -t "$THREADS" -o "$OUT_DIR" \
      -primer_f "$PRIMER_F" -primer_r "$PRIMER_R"
    du -sh "$OUT_DIR" > "$RESULTS/run.du"
    ;;
esac
