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
