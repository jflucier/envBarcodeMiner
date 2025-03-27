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
SHORT_OPTS="h:t:o:tmp:primer_f:primer_r:db:"
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
$primer_r" > ${tmp}/primers.fa

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

  echo "### Thread $thread_id: running ${index_path} ###"

  local fa_path="${index_path%.fm9}"
  local FA=$(basename "${fa_path}")

  cp "${fa_path}"* "${tmp}/"

  # Construct the base singularity command with explicit PATH
  local singularity_cmd="singularity exec --writable-tmpfs -e \
    -H \"${tmp}\" \
    -B \"${tmp}:${tmp}\" \
    --env \"PATH=/opt/dicey/bin:/usr/bin:$PATH\" \
    \"${DICEY_SIF}\""

  eval "${singularity_cmd} /opt/dicey/bin/dicey search \
    -i \"${tmp}/primer3_config/\" \
    -o \"${tmp}/${FA}.json.gz\" \
    -g \"${tmp}/${FA}.gz\" \
    \"${tmp}/primers.fa\""

  eval "${singularity_cmd} python3 /opt/dicey/scripts/json2tsv.py \
    -m amplicon \
    -j \"${tmp}/${FA}.json.gz\" > \"${tmp}/${FA}.tsv\""

  mkdir -p "${out}/dicey/part/"
  cp "${tmp}/${FA}.tsv" "${out}/dicey/part/"
  cp "${tmp}/${FA}.json.gz" "${out}/dicey/part/"

  rm "${tmp}/${FA}"*
}

TOTAL_INDEX=$(ls ${fa_list}/*.fm9 | wc -l)
echo "will run dicey search on ${TOTAL_INDEX} indexes using ${threads} threads"
# --- Get the list of index files ---
index_files=$(ls "${fa_list}"/*.fm9)
# --- Loop through index files and run in parallel ---
counter=0
for index_path in $index_files; do
  counter=$((counter + 1))
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



#### single thread method
#for ((i=1; i<=job_nbr; i++)); do
#  echo "### running ${fa_path} (${i} / ${job_nbr}) ###"
#
#  index_path=$(ls ${fa_list}/*.fm9 | awk "NR==${i}")
#  fa_path=${index_path%.fm9}
#  echo "copying dicey index ${fa_path} to temp folder"
#  cp ${fa_path}* "${tmp}/"
#
#  FA=$(basename ${fa_path})
#
#  echo "running dicey search on ${FA}"
#  singularity exec --writable-tmpfs -e \
#  -H ${tmp} \
#  -B ${tmp}:${tmp} \
#  ${DICEY_SIF} \
#  /opt/dicey/bin/dicey search \
#  -i ${tmp}/primer3_config/ \
#  -o ${tmp}/${FA}.json.gz \
#  -g ${tmp}/${FA}.gz \
#  ${tmp}/primers.fa
#
#  echo "convert json to tsv for $FA"
#  singularity exec --writable-tmpfs -e \
#  -H ${tmp} \
#  -B ${tmp}:${tmp} \
#  ${DICEY_SIF} \
#  python3 /opt/dicey/scripts/json2tsv.py \
#  -m amplicon \
#  -j ${tmp}/${FA}.json.gz > ${tmp}/${FA}.tsv
#
#  echo "copying results to ${out}"
#  mkdir -p ${out}/dicey/part/
#  cp ${tmp}/${FA}.tsv ${out}/dicey/part/
#  cp ${tmp}/${FA}.json.gz ${out}/dicey/part/
#
#  echo "cleaning up temp"
#  rm ${tmp}/${FA}*
#done

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

echo "Generate dicey hits TSV report: hits.taxid.tsv"
sqlite3 ${out}/envBarcodeMiner.results.sqlite '.separator "\t"' '.header off' '
select distinct
   taxid,
   Chrom,
   Seq
from hits_taxid
order by taxid
' > ${out}/dicey/hits.taxid.tsv

echo "Generate dicey hits lineage TSV report: hits.lineage.tsv"

input_file="${out}/dicey/hits.taxid.tsv"
output_file="${out}/dicey/hits.lineage.tsv"

# Get unique taxids
unique_taxids=$(awk -F'\t' '{print $1}' "$input_file" | sort -u)
total_taxids=$(echo "$unique_taxids" | wc -l)
processed_taxids=0

# Function to process a single taxid
process_taxid() {
  local taxid_to_process="$1"
  local thread_id="$2"

#  echo "Thread $thread_id: Processing taxid $taxid_to_process"

  local tmp_taxid=""
  local tmp_id=1

  awk -F'\t' -v tid="$taxid_to_process" '$1 == tid' "$input_file" | while IFS=$'\t' read -r taxid acc seq ; do
    if [ "$taxid" = "$tmp_taxid" ]; then
#      echo "Thread $thread_id: $taxid == $tmp_taxid --> ID=${tmp_id}"
      local lineage_with_id="${lineage}_${tmp_id}"
      # Use printf to avoid issues with special characters in lineage
      printf "%s\t%s\t%s\t%s\n" "$taxid" "$acc" "$lineage_with_id" "$seq" >> "$output_file"
    else
      tmp_id=1
#      echo "Thread $thread_id: $taxid != $tmp_taxid --> ID=${tmp_id}"
      taxon_str=$(
        taxons=$(singularity exec --writable-tmpfs -e \
        -H "${tmp}" -B "${tmp}:${tmp}" -B "${db}:${db}" "${DICEY_SIF}" \
        perl /opt/taxdb/scripts/taxdb_query.pl --taxon "$taxid" --mode lineage "${db}/taxonomy_db.sqlite")
        for t in $taxons;
        do
          singularity exec --writable-tmpfs -e \
          -H "${tmp}" \
          -B "${tmp}:${tmp}" \
          -B "${db}:${db}" \
          "${DICEY_SIF}" \
          perl /opt/taxdb/scripts/taxdb_query.pl --taxon "$t" "${db}/taxonomy_db.sqlite" | grep -m 1 "scientific name";
        done |
          cut -f 1-3,15,16 |
          grep -P 'kingdom|phylum|class|order|family|genus|species' |
          grep -vP '\tsuper\w+' |
          grep -vP '\tsub\w+' |
          grep -vP '\tno rank' |
          sed "s/'/ /g" | cut -f 4 | perl -ne 'chomp($_); print $_ . ","'
      )

      lineage=$(
      perl -e "
      my \$tt = '$taxon_str';
      my @t = split(',',\$tt);
      my @rv = reverse(@t);
      my \$s = join(';',@rv);
      print \$s. \";$acc\" . \"\n\";
      "
      )
      local lineage_with_id="${lineage}_${tmp_id}"
      printf "%s\t%s\t%s\t%s\n" "$taxid" "$acc" "$lineage_with_id" "$seq" >> "$output_file"
    fi
    tmp_taxid="$taxid"
    tmp_id=$((tmp_id+1))
  done

#  processed_taxids=$((processed_taxids + 1))
#  progress=$((processed_taxids * 100 / total_taxids))
#  printf "Progress: [%-${progress}s] %d%%\r" $(printf "=" %.0s {1..$progress}) $progress
}

# Initialize output file with header
echo -e "taxid\tacc\tlineage\tseq" > "$output_file"

# Launch threads to process unique taxids
thread_id=1
counter=1
for tid in $unique_taxids; do
  echo "Processing ${tid} (${counter} / ${total_taxids})"
  process_taxid "$tid" "$thread_id" &
  ((thread_id++))
  ((counter++))
  if (( thread_id > threads )); then
    wait # Wait for all threads to finish before launching more
    thread_id=1
  fi
done

wait # Wait for any remaining threads

echo "Processing complete. Results in $output_file"

#### single thread
#echo -e "taxid\tacc\tlineage\tseq" > ${out}/dicey/hits.lineage.tsv
#tmp_taxid=""
#while IFS=$'\t' read -r taxid acc seq ; do
#  if [ "$taxid" = "$tmp_taxid" ]; then
#    echo "$taxid == $tmp_taxid --> ID=${tmp_id}"
#    echo -e "$taxid\t$acc\t${lineage}_${tmp_id}\t$seq" >> ${out}/dicey/hits.lineage.tsv
#  else
#    tmp_id=1
#    echo "$taxid != $tmp_taxid --> ID=${tmp_id}"
#    taxon_str=$(
#      taxons=$(singularity exec --writable-tmpfs -e \
#      -H ${tmp} -B ${tmp}:${tmp} -B "${db}:${db}" ${DICEY_SIF} \
#      perl /opt/taxdb/scripts/taxdb_query.pl --taxon $taxid --mode lineage ${db}/taxonomy_db.sqlite)
#      for t in $taxons;
#      do
#        singularity exec --writable-tmpfs -e \
#        -H ${tmp} \
#        -B ${tmp}:${tmp} \
#        -B "${db}:${db}" \
#        ${DICEY_SIF} \
#        perl /opt/taxdb/scripts/taxdb_query.pl --taxon ${t} ${db}/taxonomy_db.sqlite | grep -m 1 "scientific name";
#      done | \
#        cut -f 1-3,15,16 | \
#        grep -P 'kingdom|phylum|class|order|family|genus|species' | \
#        grep -vP '\tsuper\w+' | \
#        grep -vP '\tsub\w+' | \
#        grep -vP '\tno rank' | \
#        sed "s/'/ /g" | cut -f 4 | perl -ne 'chomp($_); print $_ . ","'
#    )
#
#    lineage=$(
#    perl -e "
#    my \$tt = '$taxon_str';
#    my @t = split(',',\$tt);
#    my @rv = reverse(@t);
#    my \$s = join(';',@rv);
#    print \$s. \";$acc\" . \"\n\";
#    "
#    )
#    echo -e "$taxid\t$acc\t${lineage}_${tmp_id}\t$seq" >> ${out}/dicey/hits.lineage.tsv
#  fi
#
#  tmp_taxid=$taxid
#  tmp_id=$((tmp_id+1))
#done < ${out}/dicey/hits.taxid.tsv

# split header and reimport to db
perl -ne '
chomp($_);
my($taxid,$acc,$lineage,$seq) = split("\t",$_);
my($kingdom,$phylum,$class,$order,$family,$genus,$species,$lacc) = split("\;",$lineage);
print "$taxid\t$acc\t$kingdom\t$phylum\t$class\t$order\t$family\t$genus\t$species\t$lacc\t$lineage\t$seq\n";
' ${out}/dicey/hits.lineage.tsv > ${out}/dicey/hits.lineage.split.tsv

sqlite3 ${out}/envBarcodeMiner.results.sqlite "
drop table hits_lineage;
create table hits_lineage (
  taxid integer,
  accession text,
  kingdom text,
  phylum text,
  class text,
  t_order text,
  family text,
  genus text,
  species text,
  t_accesion text,
  lineage text,
  seq text
);
"
sqlite3 ${out}/envBarcodeMiner.results.sqlite '.separator "\t"' ".import ${out}/dicey/hits.lineage.split.tsv hits_lineage"

sqlite3 ${out}/envBarcodeMiner.results.sqlite '.separator "\t"' '.header off' '
select
   Seq,
   group_concat(distinct kingdom),
   group_concat(distinct phylum),
   group_concat(distinct class),
   group_concat(distinct t_order),
   group_concat(distinct family),
   group_concat(distinct genus),
   group_concat(distinct species),
   group_concat(distinct t_accesion)
from hits_lineage
group by Seq
' > ${out}/hits.lineage.byseq.tsv

# produce fasta
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
