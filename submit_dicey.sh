#!/bin/bash

set -e

ml apptainer
echo "FA path is ${FA_DB}"
export FA_PATH=$(ls ${FA_DB}/*.fa | awk "NR==$SLURM_ARRAY_TASK_ID")
#export out=${OUTPATH}

echo "copying NT db fasta part ${fa} to compute node"
cp ${FA_PATH} ${SLURM_TMPDIR}/
echo "copying primer definition to compute node"
cp ${FA_PRIMER} ${SLURM_TMPDIR}/
export PRIMERS=$(basename ${FA_PRIMER})
cp ${DICEY_CONTAINER} ${SLURM_TMPDIR}/
export DICEY_SIF=$(basename ${DICEY_CONTAINER})

echo "copying primer3 configs from container to ${SLURM_TMPDIR}"
singularity exec --writable-tmpfs -e \
-B ${SLURM_TMPDIR}:${SLURM_TMPDIR} \
${SLURM_TMPDIR}/${DICEY_SIF} \
cp -r /opt/dicey/src/primer3_config ${SLURM_TMPDIR}/

FA=$(basename ${FA_PATH})
echo "zipping genome with bgzip for $FA"
singularity exec --writable-tmpfs -e \
-B ${SLURM_TMPDIR}:${SLURM_TMPDIR} \
${SLURM_TMPDIR}/${DICEY_SIF} \
bgzip --threads 12 ${SLURM_TMPDIR}/${FA}

echo "indexing genome with dicey for $FA"
singularity exec --writable-tmpfs -e \
-H ${SLURM_TMPDIR} \
-B ${SLURM_TMPDIR}:${SLURM_TMPDIR} \
${SLURM_TMPDIR}/${DICEY_SIF} \
dicey index -o ${SLURM_TMPDIR}/${FA}.fm9 ${SLURM_TMPDIR}/${FA}.gz

echo "indexing genome with samtools for $FA"
singularity exec --writable-tmpfs -e \
-B ${SLURM_TMPDIR}:${SLURM_TMPDIR} \
${SLURM_TMPDIR}/${DICEY_SIF} \
samtools faidx ${SLURM_TMPDIR}/${FA}.gz

echo "running dicey search for $FA"
singularity exec --writable-tmpfs -e \
-H ${SLURM_TMPDIR} \
-B ${SLURM_TMPDIR}:${SLURM_TMPDIR} \
${SLURM_TMPDIR}/${DICEY_SIF} \
/opt/dicey/bin/dicey search \
-i ${SLURM_TMPDIR}/primer3_config/ \
-o ${SLURM_TMPDIR}/${FA}.json.gz \
-g ${SLURM_TMPDIR}/${FA}.gz \
${SLURM_TMPDIR}/${PRIMERS}

echo "convert json to tsv for $FA"
singularity exec --writable-tmpfs -e \
-H ${SLURM_TMPDIR} \
-B ${SLURM_TMPDIR}:${SLURM_TMPDIR} \
${SLURM_TMPDIR}/${DICEY_SIF} \
python3 /opt/dicey/scripts/json2tsv.py \
-m amplicon \
-j ${SLURM_TMPDIR}/${FA}.json.gz > ${SLURM_TMPDIR}/${FA}.tsv

echo "copying results to ${OUTPATH}"
mkdir -p ${OUTPATH}
cp ${SLURM_TMPDIR}/${FA}.tsv ${OUTPATH}/
cp ${SLURM_TMPDIR}/${FA}.json.gz ${OUTPATH}/

echo "done"
