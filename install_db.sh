#!/bin/bash

set -e

help_message () {
	echo ""
	echo "Usage: install_db.sh [-db /path/to/db] [-c True|False]"
	echo "Options:"

	echo ""
	echo "	-db STR	path to database dir (default to envBarcodeMiner_installation_path/db)"
  echo "	-c BOOL	Specify if download core_nt files downloaded from NCBI should be deleted (defaults to false)"
  echo ""
  echo "  -h --help	Display help"

	echo "";
}

export ENVBARCODEMINER_PATH=$(dirname "$0")
cd ${ENVBARCODEMINER_PATH}

# initialisation
db="false"
clean="false"

# load in params
SHORT_OPTS="ht:db:c:"
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
    -db) db=$2; shift 2;;
    -c) clean=$2; shift 2;;
    --) help_message; exit 1; shift; break ;;
		*) break;;
	esac
done

if [ "$db" = "false" ]; then
    db=${ENVBARCODEMINER_PATH}/db
fi

mkdir -p ${db}

echo "Downloading core_nt db from NCBI (this might take a while...). Requires 500GB of disk space."
python download_envBarcodeMiner_db.py db=${db}

echo "Generating envBarcodeMiner.core_nt.fa (this might take a while... again!). Requires another 1TB of disk space"
singularity exec --writable-tmpfs -e \
-B ${ENVBARCODEMINER_PATH}:${ENVBARCODEMINER_PATH} \
${ENVBARCODEMINER_PATH}/containers/envBarcodeMiner.sif \
blastdbcmd -entry all -db ${ENVBARCODEMINER_PATH}/db/core_nt -out ${ENVBARCODEMINER_PATH}/db/envBarcodeMiner.core_nt.fa

echo "Splitting up envBarcodeMiner.core_nt.fa into parts"
mkdir -p ${db}/fa_split
singularity exec --writable-tmpfs -e \
-B ${ENVBARCODEMINER_PATH}:${ENVBARCODEMINER_PATH} \
${ENVBARCODEMINER_PATH}/containers/envBarcodeMiner.sif \
seqkit split --threads 8 --by-size 125000 \
--out-dir ${ENVBARCODEMINER_PATH}/db/fa_split \
${ENVBARCODEMINER_PATH}/db/envBarcodeMiner.core_nt.fa

TOTAL_FA=$(ls ${ENVBARCODEMINER_PATH}/db/fa_split/* | wc -l)
echo "Generated a total of ${TOTAL_FA} fasta for dicey search"

if [ "$clean" != "false" ]; then
  echo "cleaning up downloaded NCBI files"
  rm ${db}/*.tar.gz* ${db}/core_nt*
fi

echo "DB installation done!"