#!/bin/bash

set -e
trap '' CHLD

help_message () {
	echo ""
	echo "Usage: run_dicey.local.sh "
	echo "Options:"

	echo ""
  echo "	-db STR	STR	path to database dir (default to envBarcodeMiner_installation_path/db)"
	echo "	-t	# of threads (default 12)"
	echo "	-primer_f	Forward primer sequence to use as input for dicey"
	echo "	-primer_r	Reverse primer sequence to use as input for dicey"
  echo "	-o STR	path to output dir"
  echo "	-tmp STR	path to temp dir"
  echo ""
  echo "  -h --help	Display help"

	echo "";
}

export ENVBARCODEMINER_PATH=$(dirname "$0")

# initialisation
db="false"
threads="12"
out="false"
tmp="false"
primer_f="false"
primer_r="false"

# load in params
SHORT_OPTS="ht:o:tmp:primer_f:primer_r:db:"
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
        -t) threads=$2; shift 2;;
        -tmp) tmp=$2; shift 2;;
        -o) out=$2; shift 2;;
        -primer_f) primer_f=$2; shift 2;;
        -primer_r) primer_r=$2; shift 2;;
        -db) db=$2; shift 2;;
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

if [ "$db" = "false" ]; then
  db=${ENVBARCODEMINER_PATH}/db
fi

if [ "$tmp" = "false" ]; then
    tmp=$out/temp
    mkdir -p $tmp
    echo "## No temp folder provided. Will use: $tmp"
fi

if [ "$primer_f" = "false" ]; then
    echo "Please provide a forward primer sequence"
    help_message; exit 1
fi

if [ "$primer_r" = "false" ]; then
    echo "Please provide a reverse primer sequence"
    help_message; exit 1
fi

fa_list=${db}/split

echo "## Database path: $db"
echo "## Forward primer sequence: $primer_f"
echo "## Reverse primer sequence: $primer_r"
echo "## Will run using ${threads} threads"

echo "generate primer fasta im temp folder"
echo ">primer_f
$primer_f
>primer_r
$primer_r" > ${out}/primers.fa

export DICEY_SIF=${ENVBARCODEMINER_PATH}/containers/envBarcodeMiner.sif

echo "copying primer3 configs from container to ${tmp}"
singularity exec --writable-tmpfs -e \
-B ${tmp}:${tmp} \
${DICEY_SIF} \
cp -r /opt/dicey/src/primer3_config ${tmp}/

# --- Function to process each FASTA index file ---
process_index() {
  local index_path="$1"
  local thread_id="$2"
  local fa_path="${index_path%.fm9}"
  local FA=$(basename "${fa_path}")

  cp "${fa_path}"* "${tmp}/"

  local singularity_cmd="singularity exec --writable-tmpfs -e \
    -H \"${tmp}\" \
    -B \"${tmp}:${tmp}\" \
    --env \"PATH=/opt/dicey/bin:/usr/bin:$PATH\" \
    \"${DICEY_SIF}\""

  eval "${singularity_cmd} /opt/dicey/bin/dicey search  -m 10000000 \
    -i \"${tmp}/primer3_config/\" \
    -o \"${tmp}/${FA}.json.gz\" \
    -g \"${tmp}/${FA}.gz\" \
    \"${out}/primers.fa\""

  eval "${singularity_cmd} python3 /opt/dicey/scripts/json2tsv.py \
    -m amplicon \
    -j \"${tmp}/${FA}.json.gz\" > \"${tmp}/${FA}.tsv\""

  mkdir -p "${out}/dicey/part/"
  cp "${tmp}/${FA}.tsv" "${out}/dicey/part/"
  cp "${tmp}/${FA}.json.gz" "${out}/dicey/part/"

  rm "${tmp}/${FA}"*
}

if [[ ! -f  ${out}/taxonomy/hits.taxid.tsv ]]; then
    
    TOTAL_INDEX=$(ls ${fa_list}/*.fm9 | wc -l)
    echo "will run dicey search on ${TOTAL_INDEX} indexes using ${threads} threads"
    # --- Get the list of index files ---
    index_files=$(ls "${fa_list}"/*.fm9)
    # --- Loop through index files and run in parallel ---
    counter=0
    for index_path in $index_files; do
      counter=$((counter + 1))
      echo "### Running on index: ${index_path} (${counter} / ${TOTAL_INDEX}) ###"
      process_index "$index_path" "$counter" &
      active_processes=$(jobs -r -p | wc -l)
    
      # Wait if we reach the maximum number of threads
      while [[ "$active_processes" -ge "$threads" ]]; do
        sleep 0.1
        active_processes=$(jobs -r -p | wc -l)
      done
    done
    
    # --- Wait for all background processes to finish ---
    wait
    
    ### check if all index runned correctly
    TOTAL_RESULTS=$(ls ${out}/dicey/part/*.tsv | wc -l)
    counter=0
    if [[ "$TOTAL_INDEX" != "$TOTAL_RESULTS" ]]; then
      echo "### Detected some error in dicey search. Will try rerunning erors: ###"
      for index_path in $index_files; do
        index_base=$(basename $index_path)
        res_file=${fa_path%.fm9}
        if [[ ! -e "${out}/dicey/part/${res_file}.tsv" ]]; then
          counter=$((counter + 1))
          echo "rerunning index ${index_base}"
          process_index "$index_path" "$counter" &
        fi
      done
    else
      echo "Dicey search done sucessfully!"
    fi
    
    echo "combine all dicey results in ${out}/dicey_results.tsv"
    cat ${out}/dicey/part/*.tsv > ${out}/dicey/dicey_results.tsv
    
    echo "trim hits accession version from all hits"
    perl -ne '
    chomp($_);
    if($_ =~ /^Amplicon\tId/){
      print $_ . "\n";
    }
    else{
      my @t = split("\t",$_);
      my $tmp = $t[4];
      my($ns) = $t[4] =~ /^(.*)\.\d+$/;
      $t[4] = $ns;
      print join("\t",@t) . "\n";
    }
    ' ${out}/dicey/dicey_results.tsv > ${out}/dicey/dicey_results.acc.tsv
    
    echo "Initialise envBarcodeMiner result db with dicey hits"
    sqlite3 ${out}/envBarcodeMiner.results.sqlite "
    drop table if exists hits;
    create table hits (
    Amplicon TEXT,
    Id INTEGER,
    Length INTEGER,
    Penalty FLOAT,
    Chrom TEXT,
    ForPos INTEGER,
    ForEnd INTEGER,
    ForTm FLOAT,
    ForName TEXT,
    ForSeq TEXT,
    ChromV TEXT,
    RevPos INTEGER,
    RevEnd INTEGER,
    RevTm FLOAT,
    RevName TEXT,
    RevSeq TEXT,
    Seq TEXT
    );
    "
    sqlite3 ${out}/envBarcodeMiner.results.sqlite '.separator "\t"' ".import ${out}/dicey/dicey_results.acc.tsv hits"
    
    sqlite3 ${out}/envBarcodeMiner.results.sqlite "
    delete from hits where Chrom='Chrom';
    "
    
    mkdir -p ${out}/taxonomy
    echo "associate taxonomic information to dicey hits"
    sqlite3 ${out}/envBarcodeMiner.results.sqlite "
    ATTACH DATABASE '${db}/taxonomy_db.sqlite' AS taxo;
    drop table if exists hits_taxid;
    create table hits_taxid as
    select
      h.Chrom || '_' || h.Id Id,
      h.Chrom,
      a.taxid,
      h.Seq
    from
      hits h
      join taxo.accession2taxid a on h.Chrom=a.\"accession\";
    "
fi

echo "Generate dicey hits TSV report: hits.taxid.tsv"
sqlite3 ${out}/envBarcodeMiner.results.sqlite '.separator "\t"' '.header off' '
select distinct
   taxid
from hits_taxid
order by taxid
' > ${out}/taxonomy/hits.taxid.tsv

echo "Generate dicey hits lineage TSV report: hits.lineage.tsv"
total=$(cat ${out}/taxonomy/hits.taxid.tsv | wc -l)

echo "### running taxdb on ${out}/taxonomy/hits.taxid.tsv"
rm -f "${out}/taxonomy/hits.lineage.tsv"
touch "${out}/taxonomy/hits.lineage.tsv"
counter=1
total=$(cat "${out}/taxonomy/hits.taxid.tsv" | wc -l)

export tmp db out DICEY_SIF
taxdb_query() {
  local taxid="$1"
  local tmp="${tmp}"
  local db="${db}"
  local out="${out}"
  local DICEY_SIF="${DICEY_SIF}"

  singularity exec --writable-tmpfs -e \
  --no-home -B "${tmp}:${tmp}" -B "${db}:${db}" -B "${out}:${out}" "${DICEY_SIF}" \
  /bin/bash -c "
  taxons=\$(perl /opt/taxdb/scripts/taxdb_query.pl --taxon \"${taxid}\" --mode lineage \"${db}/taxonomy_db.sqlite\");
  intermediate_t=\$(echo \"\$taxons\" | sed \"s/'/'/g; s/\t/','/g\");

  new_t=\"'\${intermediate_t}'\";

  sqlite3 ${db}/taxonomy_db.sqlite \
  \"SELECT printf('%%s\t%%s\n', '${taxid}', group_concat(name_txt, ';')) FROM (SELECT name_txt FROM taxonomy WHERE taxid IN (\$new_t) ORDER BY rank_number ASC);\"
  "
}

export -f taxdb_query
echo "Starting parallel processing..."
/usr/bin/env parallel --jobs $threads \
--joblog "${out}/taxonomy/taxdb_parallel.log" taxdb_query :::: "${out}/taxonomy/hits.taxid.tsv" >> "${out}/taxonomy/hits.lineage.tsv"

#while IFS=$'\t' read -r taxid; do
#  echo "running taxonomic id ${taxid} (${counter} / ${total})"
#  ((counter++))
#
#  singularity exec --writable-tmpfs -e \
#  --no-home -B "${tmp}:${tmp}" -B "${db}:${db}" -B "${out}:${out}" "${DICEY_SIF}" \
#  /bin/bash -c "
#  taxons=\$(perl /opt/taxdb/scripts/taxdb_query.pl --taxon \"${taxid}\" --mode lineage \"${db}/taxonomy_db.sqlite\");
#  intermediate_t=\$(echo \"\$taxons\" | sed \"s/'/'/g; s/\t/','/g\");
#
#  new_t=\"'\${intermediate_t}'\";
#
#  sqlite3 ${db}/taxonomy_db.sqlite \".separator '\t'\" \"select '${taxid}', group_concat(name_txt, ';') from (select name_txt from taxonomy where taxid in (\$new_t) order by rank_number asc);\"
#
#  " >> "${out}/taxonomy/hits.lineage.tsv"
#done < "${out}/taxonomy/hits.taxid.tsv"
echo "Processing complete. Results in ${out}/taxonomy/hits.lineage.tsv"

# split header and reimport to db
echo "inserting lineage info to db"
perl -ne '
chomp($_);
my($taxid,$lineage) = split(/\t/,$_);
my($kingdom,$phylum,$class,$order,$family,$genus,$species) = split(/;/,$lineage);
print join("\t", $taxid, $kingdom, $phylum, $class, $order, $family, $genus, $species, $lineage) . "\n";
' ${out}/taxonomy/hits.lineage.tsv > ${out}/taxonomy/hits.lineage.split.tsv

sqlite3 ${out}/envBarcodeMiner.results.sqlite "
drop table if exists taxo_lineage;
create table taxo_lineage (
  taxid integer,
  kingdom text,
  phylum text,
  class text,
  t_order text,
  family text,
  genus text,
  species text,
  lineage text
);
"
sqlite3 ${out}/envBarcodeMiner.results.sqlite '.separator "\t"' ".import ${out}/taxonomy/hits.lineage.split.tsv taxo_lineage"

echo "generating TSV report: hits.lineage.byseq.tsv"
sqlite3 ${out}/envBarcodeMiner.results.sqlite  '.separator "\t"' '.header on' "
select
  h.Seq,
  group_concat(distinct t.kingdom) kingdom,
  group_concat(distinct t.phylum) phylum,
  group_concat(distinct t.class) class,
  group_concat(distinct t.t_order) t_order,
  group_concat(distinct t.family) family,
  group_concat(distinct t.genus) genus,
  group_concat(distinct t.species) species,
  group_concat(distinct h.Chrom) accession
from hits_taxid h
join taxo_lineage t on h.taxid=t.taxid
group by 1;
" > ${out}/hits.lineage.byseq.tsv

echo "generating FASTA with accessions: hits.lineage.fa"
perl -ne '
chomp($_);
my($seq,@t) = split("\t",$_);
if(length($seq) >= 20){
  my $h = "";
  foreach my $tc (@t){
    my @tmp = split(",",$tc);
    if(scalar(@tmp) > 1){
      break;
    }
    else{
      $h .= "$tc\;";
    }
  }
  chop($h);
  print "\>$h\n$seq\n";
}
' ${out}/hits.lineage.byseq.tsv > ${out}/hits.lineage.fa

echo "generating FASTA no accessions: ${out}/hits.lineage.noacc.fa"
perl -ne '
chomp($_);
my($seq,@t) = split("\t",$_);
pop(@t);
if(length($seq) >= 20){
  my $h = "";
  foreach my $tc (@t){
    my @tmp = split(",",$tc);
    if(scalar(@tmp) > 1){
      break;
    }
    else{
      $h .= "$tc\;";
    }
  }
  chop($h);
  print "\>$h\n$seq\n";
}
' ${out}/hits.lineage.byseq.tsv > ${out}/hits.lineage.noacc.fa

echo "done"
