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

# load in params
SHORT_OPTS="ht:o:tmp:db:"
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

echo "## Database path: $db"
echo "## Will run using ${threads} threads"
export DICEY_SIF=${ENVBARCODEMINER_PATH}/containers/envBarcodeMiner.sif

echo "Generate dicey hits TSV report: hits.taxid.tsv"
sqlite3 ${out}/envBarcodeMiner.results.sqlite '.separator "\t"' '.header off' '
select distinct
   taxid
from hits_taxid
order by taxid
' > ${out}/taxonomy/hits.taxid.tsv

total=$(cat ${out}/taxonomy/hits.taxid.tsv | wc -l)
echo "Generate dicey hits lineage TSV report: hits.lineage.tsv. Total hits = $total"


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
  \"SELECT '${taxid}' || CHAR(9) || group_concat(name_txt, ';') || CHAR(10) FROM (SELECT name_txt FROM taxonomy WHERE taxid IN (\$new_t) ORDER BY rank_number ASC);\"
  "
}

export -f taxdb_query
echo "Starting parallel processing..."
/usr/bin/env parallel --jobs $threads \
--joblog "${out}/taxonomy/taxdb_parallel.log" taxdb_query :::: "${out}/taxonomy/hits.taxid.tsv" >> "${out}/taxonomy/hits.lineage.tsv"

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
