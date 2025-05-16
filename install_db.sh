#!/bin/bash

set -e
trap '' CHLD

help_message () {
	echo ""
	echo "Usage: install_db.sh [-db /path/to/db] [-c True|False]"
	echo "Options:"

	echo ""
	echo "	-db STR	path to database dir (default to envBarcodeMiner_installation_path/db)"
  echo "	-c BOOL	Specify if download core_nt files downloaded from NCBI should be deleted (defaults to false)"
  echo "	-t INT	Maximum number of threads to use (defaults 4)"

  echo ""
  echo "  -h --help	Display help"

	echo "";
}

export ENVBARCODEMINER_PATH=$(dirname "$0")
export CONTAINER="${ENVBARCODEMINER_PATH}/containers/envBarcodeMiner.sif"
echo "container path: ${CONTAINER}"
cd ${ENVBARCODEMINER_PATH}

# initialisation
db="false"
clean="false"
threads="4"

# load in params
SHORT_OPTS="ht:db:c:t:"
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
	case "$1" in
		-h | --help) help_message; exit 1; shift 1;;
    -db) db=$2; shift 2;;
    -c) clean=$2; shift 2;;
    -t) threads=$2; shift 2;;
    --) help_message; exit 1; shift; break ;;
		*) break;;
	esac
done

if [ "$db" = "false" ]; then
  db=${ENVBARCODEMINER_PATH}/db
fi

if [[ "$threads" =~ ^[0-9]+$ ]]; then
  echo "Will use ${threads} threads"
else
  echo "$threads is not a valid integer integer."
  help_message; exit 1;
fi

echo "### Database will be installed in this path: ${db} ###"
mkdir -p ${db}

echo "container path: ${CONTAINER}"

echo "### Downloading NCBI taxonomy ###"
mkdir -p ${db}/taxonomy
cd ${db}/taxonomy

echo "container path: ${CONTAINER}"

if [ -e "${db}/taxonomy/taxdump.tar.gz" ]; then
  echo "File ${db}/taxonomy/taxdump.tar.gz already exists. Will skip download."
else
  wget ftp://ftp.ncbi.nih.gov/pub/taxonomy/taxdump.tar.gz
fi
tar -zxvf taxdump.tar.gz

if [ -e "${db}/taxonomy/nucl_gb.accession2taxid" ]; then
  echo "File ${db}/taxonomy/nucl_gb.accession2taxid already exists. Will skip download."
else
  wget https://ftp.ncbi.nih.gov/pub/taxonomy/accession2taxid/nucl_gb.accession2taxid.gz
  echo "Extracting nucl_gb.accession2taxid.gz..."
  gunzip nucl_gb.accession2taxid.gz
fi

if [ -e "${db}/taxonomy/nucl_wgs.accession2taxid.EXTRA" ]; then
  echo "File ${db}/taxonomy/nucl_wgs.accession2taxid.EXTRA already exists. Will skip download."
else
  wget https://ftp.ncbi.nih.gov/pub/taxonomy/accession2taxid/nucl_wgs.accession2taxid.EXTRA.gz
  echo "Extracting nucl_wgs.accession2taxid.EXTRA.gz..."
  gunzip nucl_wgs.accession2taxid.EXTRA.gz
fi

if [ -e "${db}/taxonomy/nucl_wgs.accession2taxid" ]; then
  echo "File ${db}/taxonomy/nucl_wgs.accession2taxid already exists. Will skip download."
else
  wget https://ftp.ncbi.nih.gov/pub/taxonomy/accession2taxid/nucl_wgs.accession2taxid.gz
  echo "Extracting nucl_wgs.accession2taxid.gz..."
  gunzip nucl_wgs.accession2taxid.gz
fi

echo "container path: ${CONTAINER}"


cd ${ENVBARCODEMINER_PATH}
echo "### Setting up taxonomy database ###"
rm -f ${db}/envBarcodeMiner_db.sqlite
echo "container path: ${CONTAINER}"
singularity exec --writable-tmpfs -e \
-B ${ENVBARCODEMINER_PATH}:${ENVBARCODEMINER_PATH} \
${CONTAINER} \
perl /opt/taxdb/scripts/taxdb_create.pl ${db}/taxonomy_db.sqlite

echo "### Importing taxonomy to db ###"
singularity exec --writable-tmpfs -e \
-B ${ENVBARCODEMINER_PATH}:${ENVBARCODEMINER_PATH} \
${CONTAINER} \
perl /opt/taxdb/scripts/taxdb_add.pl ${db}/taxonomy_db.sqlite ${db}/taxonomy

echo "### Importing nucl_gb, nucl_wgs and nucl_wgs.extra to db ###"
sqlite3 ${db}/taxonomy_db.sqlite '.separator "\t"' '.header on' ".import ${db}/taxonomy/nucl_gb.accession2taxid accession2taxid"
sqlite3 ${db}/taxonomy_db.sqlite '.separator "\t"' '.header on' ".import ${db}/taxonomy/nucl_wgs.accession2taxid accession2taxid"
sqlite3 ${db}/taxonomy_db.sqlite '.separator "\t"' '.header on' ".import ${db}/taxonomy/nucl_wgs.accession2taxid.EXTRA accession2taxid"

echo "### Indexing taxonomy db ###"
sqlite3 ${db}/taxonomy_db.sqlite "
create index NAME_taxid_idx on NAME(tax_id);
create index NODE_taxid_idx on NODE(tax_id);
create index accession2taxid_accession_idx on accession2taxid(accession);
create index accession2taxid_taxid_idx on accession2taxid(taxid);
create index accession2taxid_accessionversion_idx on accession2taxid(\"accession.version\");
"

sqlite3 ${db}/taxonomy_db.sqlite "
drop table if exists taxonomy;
create table taxonomy as
SELECT
  NODE.tax_id taxid,
  NODE.rank,
  NAME.name_txt
FROM NAME
LEFT JOIN NODE ON NODE.tax_id = NAME.tax_id
WHERE
  NAME.name_class = 'scientific name'
  AND NODE.rank in ('kingdom','phylum','class','order','family','genus','species');
"

sqlite3 ${db}/taxonomy_db.sqlite "
alter table taxonomy add column rank_number INTEGER;
update taxonomy set rank_number=1 where rank='kingdom';
update taxonomy set rank_number=2 where rank='phylum';
update taxonomy set rank_number=3 where rank='class';
update taxonomy set rank_number=4 where rank='order';
update taxonomy set rank_number=5 where rank='family';
update taxonomy set rank_number=6 where rank='genus';
update taxonomy set rank_number=7 where rank='species';
create index taxonomy_id_rank_idx on taxonomy(rank_number,taxid);
"

echo "### Done setting up taxonomy db ###"

echo "### Downloading core_nt db from NCBI (this might take a while... only 1 thread supported). Requires 500GB of disk space. ###"
mkdir -p ${db}/NCBI
python download_envBarcodeMiner_db.py db=${db}/NCBI

echo "### Generating envBarcodeMiner.core_nt.fa (this might take a while... again single thread only!). Requires another 1TB of disk space ###"
singularity exec --writable-tmpfs -e \
-B ${ENVBARCODEMINER_PATH}:${ENVBARCODEMINER_PATH} \
${CONTAINER} \
blastdbcmd -entry all -db ${db}/NCBI/core_nt -out ${db}/envBarcodeMiner.core_nt.fa

echo "### Splitting up envBarcodeMiner.core_nt.fa into parts ###"
FA_SPLIT_DIR="${db}/split"
mkdir -p ${FA_SPLIT_DIR}
singularity exec --writable-tmpfs -e \
-B ${ENVBARCODEMINER_PATH}:${ENVBARCODEMINER_PATH} \
${CONTAINER} \
seqkit split --threads ${threads} --by-size 125000 \
--out-dir ${FA_SPLIT_DIR} \
${db}/envBarcodeMiner.core_nt.fa

fasta_files=$(ls ${FA_SPLIT_DIR}/*.fa)
TOTAL_FA=$(ls ${fasta_files} | wc -l)
echo "### Generated a total of ${TOTAL_FA} fasta to index ###"

if [ "$clean" != "false" ]; then
  echo "### cleaning up downloaded NCBI files since they are not needed anymore ###"
  rm -r ${db}/NCBI
fi

# --- Function to process each FASTA file ---
process_fasta() {
  local fa_path="$1"
  local fm9_file="${fa_path}.fm9"
  local thread_id="$2"

  if [[ ! -e "${fm9_file}" ]]; then

    # Define the singularity command with explicit PATH
    local singularity_cmd="singularity exec --writable-tmpfs -e \
      -B \"${FA_SPLIT_DIR}:${FA_SPLIT_DIR}\" \
      --env \"PATH=/opt/dicey/bin:/usr/bin:$PATH\" \
      \"${CONTAINER}\""

    echo "### Indexing ${fa_path} ###"

    echo "Thread $thread_id: zipping genome with bgzip for ${fa_path}"
    eval "${singularity_cmd} bgzip --force --threads 1 \"${fa_path}\""

    echo "Thread $thread_id: indexing genome with dicey for ${fa_path}"
    eval "${singularity_cmd} dicey index -o \"${fa_path}.fm9\" \"${fa_path}.gz\""

    echo "Thread $thread_id: indexing genome with samtools for ${fa_path}"
    eval "${singularity_cmd} samtools faidx \"${fa_path}.gz\""
  else
    echo "Thread $thread_id: File ${fm9_file} already exists. Skipping."
  fi
}

echo "### Indexing ${TOTAL_FA} fasta... ###"
counter=0
for fa_path in $fasta_files; do
  counter=$((counter + 1))
  process_fasta "$fa_path" "$counter" &
  active_processes=$(jobs -r -p | wc -l)
  while [[ "$active_processes" -ge "${threads}" ]]; do
    sleep 0.1
    active_processes=$(jobs -r -p | wc -l)
  done
done

# --- Wait for all background processes to finish ---
wait

# check if fm9 files = total fa to see if errors
TOTAL_INDEX=$(ls ${db}/fa_split/*.fa.fm9 | wc -l)
if [[ "$TOTAL_INDEX" != "$TOTAL_FA" ]]; then
  echo "### Detected some error in dicey index generation. Will try to recuperate. ###"
  fasta_files=$(ls ${FA_SPLIT_DIR}/*.fa.gz)
  for fa_path in $fasta_files; do
    fa_path=${fa_path%.gz}
    if [[ ! -e "${fa_path}.fm9" ]]; then
        echo "A problem was detected with $fm9_file."
        echo "will regenerate"
        process_fasta "$fa_path" "$counter"
    fi
  done
fi

TOTAL_INDEX=$(ls ${db}/fa_split/*.fa.fm9 | wc -l)
if [[ "$TOTAL_INDEX" != "$TOTAL_FA" ]]; then
  echo "### Still detected some error in dicey index generation. Please investigate these files: ###"
  fasta_files=$(ls ${FA_SPLIT_DIR}/*.fa.gz)
  for fa_path in $fasta_files; do
    fa_path=${fa_path%.gz}
    if [[ ! -e "${fa_path}.fm9" ]]; then
        echo "${fa_path}"
    fi
  done
else
  echo "### DB installation done sucessfully! ###"
fi



