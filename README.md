# setup envBarcodeMiner
you need apptainer (https://apptainer.org/)
load on ip34: ml StdEnv/2023 apptainer/1.3.5
```
export INSTALLATION_PATH=/fast/def-ilafores/
export ENVBARCODEMINER_PATH=${INSTALLATION_PATH}/envBarcodeMiner
cd ${INSTALLATION_PATH}
git clone git@github.com:jflucier/envBarcodeMiner.git
```
### setup dicey container
```
cd ${ENVBARCODEMINER_PATH}
cd containers
singularity build --force --fakeroot envBarcodeMiner.sif envBarcodeMiner.def
```
### setup db
Requires ~2Tb of space. Downloads Core_nt and creates a dicey index. 
```
cd ${ENVBARCODEMINER_PATH}
sh install_db.sh
```
### analysis example ###
```
export ANALYSIS_PATH=/fast/def-ilafores/20250318_envBarcodeMiner_test
cd ${ANALYSIS_PATH}
```
### show help message
```
sh /fast/def-ilafores/envBarcodeMiner/run_envBarcodeMiner.local.sh -h

sh /fast/def-ilafores/envBarcodeMiner/run_envBarcodeMiner.local.sh -t 12 \
-o $PWD -primer_f CTTGGTCATTTAGAGGAAGTAA -primer_r GCTGCGTTCTTCATCGATGC
```

### Run with degenerate pairs
Degenerate primers may be useful for some target sequences. These utility scripts generate every
possible non-degenerate combinations from a given degenerate combination. Run a while loop to create
a subdir by primer pair and execute the pipeline on each. Future development will integrate parallel
execution of multiple runs.

```
mkdir -p primer_pairs
bash $ENVBARCODEMINER_PATH/dedegenerate.sh CYGTRCDAAGGTAGCATA TARTYCAACATCGRGGTC primer_pairs/all_primers.tsv

while read -r FWD REV; do
    OUT_DIR=$ANALYSIS_PATH/primer_pairs/${FWD}_${REV}
    #if [[ -f $OUT_DIR ]]
    mkdir -p $OUT_DIR
    nice sh $ENVBARCODEMINER_PATH/run_envBarcodeMiner.local.sh -t 36 -o $OUT_DIR -primer_f $FWD -primer_r $REV
done < primer_pairs/all_primers.tsv
```

### Resource benchmark (c-3t)
Measures time, CPU-hours, peak memory and disk for: downloading the db, building the index, and one primer search.
Three jobs on `c-3t` (internet access), each starting only if the previous one succeeded:

| stage | what | CPUs | mem | time |
|---|---|---|---|---|
| `download` | taxonomy files + core_nt (single-threaded) | 1 | 8G | 3 d |
| `db` | `install_db.sh -t 36` (skips downloads; sqlite, blastdbcmd, split, dicey index) | 36 | 750G | 7 d |
| `run` | `run_envBarcodeMiner.local.sh -t 12`, ITS1F/ITS2 primers (above) | 12 | 250G | 3 d |

```
cd ${ENVBARCODEMINER_PATH}
bash benchmark/submit_benchmark.sh           # all three (or e.g. `... db run` for a subset)
bash benchmark/report.sh                     # once the jobs have ended
```
`report.sh` prints wall hours, CPU-hours used, CPU-hours allocated, peak memory (from `sacct`) and disk (`du` at the end of each job).
Overrides: `DB_DIR` (default `./db`), `DB_THREADS`, `RUN_THREADS`, `CLEAN`, `PRIMER_F`, `PRIMER_R`.
Logs: `benchmark/results/<stage>_<jobid>.out`.
