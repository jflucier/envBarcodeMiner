#!/bin/bash

set -e

help_message () {
	echo ""
	echo "Usage: run_dicey.local.sh "
	echo "Options:"

	echo ""
	echo "	-fa_list STR	Path to Fasta list to run dicey amplification against (defaults to envBarcodeMiner_install/db/fa_split)"
	echo "	-t	# of threads (default 12)"
	echo "	-primer_f	Forward primer sequence to use as input for dicey"
	echo "	-primer_r	Reverse primer sequence to use as input for dicey"
  echo "	-o STR	path to output dir"
  echo "	-tmp STR	path to temp dir"
  echo ""
  echo "  -h --help	Display help"

	echo "";
}

export EXE_PATH=$(dirname "$0")

# initialisation
threads="12"
fa_list="false"
out="false"
tmp="false"
primer_f="false"
primer_r="false"

# load in params
SHORT_OPTS="h:t:fa_list:o:tmp:primer_f:primer_r:"
LONG_OPTS='help'

OPTS=$(getopt -o $SHORT_OPTS --long $LONG_OPTS -- "$@")
# make sure the params are entered correctly
if [ $? -ne 0 ];
then
    help_message;
    exit 1;
fi

# loop through input params
while true; do
    # echo $1
	case "$1" in
		    -h | --help) help_message; exit 1; shift 1;;
        -t) threads=$2; shift 2;;
        -tmp) tmp=$2; shift 2;;
        -o) out=$2; shift 2;;
		    -fa_list) fa_list=$2; shift 2;;
        -primer_f) primer_f=$2; shift 2;;
        -primer_r) primer_r=$2; shift 2;;
        --) help_message; exit 1; shift; break ;;
		*) break;;
	esac
done

if [ "$out" = "false" ]; then
    echo "Please provide an output path"
    help_message; exit 1
else
    mkdir -p $out
    echo "## Results wil be stored to this path: $out/"
fi

if [ "$tmp" = "false" ]; then
    tmp=$out/temp
    mkdir -p $tmp
    echo "## No temp folder provided. Will use: $tmp"
fi

if [ "$fa_list" = "false" ]; then
      fa_list=${EXE_PATH}/db/fa_split
fi

if [ "$primer_f" = "false" ]; then
    echo "Please provide a forward primer sequence"
    help_message; exit 1
fi

if [ "$primer_r" = "false" ]; then
    echo "Please provide a reverse primer sequence"
    help_message; exit 1
fi

echo "## Fasta path: $fa_list"
echo "## Forward primer sequence: $primer_f"
echo "## Reverse primer sequence: $primer_r"
echo "## Will run using ${threads} threads"

echo "generate primer definition file im temp folder"
echo ">primer_f
$primer_f
>primer_r
$primer_r" > ${tmp}/primers.fa

export DICEY_SIF=${EXE_PATH}/containers/envBarcodeMiner.sif

echo "copying primer3 configs from container to ${tmp}"
singularity exec --writable-tmpfs -e \
-B ${tmp}:${tmp} \
${DICEY_SIF} \
cp -r /opt/dicey/src/primer3_config ${tmp}/

job_nbr=$(ls ${fa_list}/* | wc -l)

for ((i=1; i<=job_nbr; i++)); do
  echo "running ${fa_path} (${i} / ${job_nbr})"

  fa_path=$(ls ${fa_list}/* | awk "NR==${i}")
  echo "copying fasta ${fa_path} to temp folder"
  cp "${fa_path}" "${tmp}/"

  FA=$(basename ${fa_path})
  echo "zipping genome with bgzip for $FA"
  singularity exec --writable-tmpfs -e \
  -B ${tmp}:${tmp} \
  ${DICEY_SIF} \
  bgzip --threads ${threads} ${tmp}/${FA}

  echo "indexing genome with dicey for $FA"
  singularity exec --writable-tmpfs -e \
  -H ${tmp} \
  -B ${tmp}:${tmp} \
  ${DICEY_SIF} \
  dicey index -o ${tmp}/${FA}.fm9 ${tmp}/${FA}.gz

  echo "indexing genome with samtools for $FA"
  singularity exec --writable-tmpfs -e \
  -B ${tmp}:${tmp} \
  ${DICEY_SIF} \
  samtools faidx ${tmp}/${FA}.gz

  echo "running dicey search for $FA"
  singularity exec --writable-tmpfs -e \
  -H ${tmp} \
  -B ${tmp}:${tmp} \
  ${DICEY_SIF} \
  /opt/dicey/bin/dicey search \
  -i ${tmp}/primer3_config/ \
  -o ${tmp}/${FA}.json.gz \
  -g ${tmp}/${FA}.gz \
  ${tmp}/${PRIMERS}

  echo "convert json to tsv for $FA"
  singularity exec --writable-tmpfs -e \
  -H ${tmp} \
  -B ${tmp}:${tmp} \
  ${DICEY_SIF} \
  python3 /opt/dicey/scripts/json2tsv.py \
  -m amplicon \
  -j ${tmp}/${FA}.json.gz > ${tmp}/${FA}.tsv

  echo "copying results to ${OUTPATH}"
  mkdir -p ${OUTPATH}
  cp ${tmp}/${FA}.tsv ${OUTPATH}/
  cp ${tmp}/${FA}.json.gz ${OUTPATH}/

  echo "cleaning up temp"
  rm ${tmp}/${FA}*
done

echo "done"
