#!/bin/bash

set -e

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

job_nbr=$(ls ${fa_list}/*.fm9 | wc -l)

for ((i=1; i<=job_nbr; i++)); do
  echo "### running ${fa_path} (${i} / ${job_nbr}) ###"

  index_path=$(ls ${fa_list}/*.fm9 | awk "NR==${i}")
  fa_path=${index_path%.fm9}
  echo "copying dicey index ${fa_path} to temp folder"
  cp "${fa_path}*" "${tmp}/"

  FA=$(basename ${fa_path})

  echo "running dicey search on ${FA}"
  singularity exec --writable-tmpfs -e \
  -H ${tmp} \
  -B ${tmp}:${tmp} \
  ${DICEY_SIF} \
  /opt/dicey/bin/dicey search \
  -i ${tmp}/primer3_config/ \
  -o ${tmp}/${FA}.json.gz \
  -g ${tmp}/${FA}.gz \
  ${tmp}/primers.fa

  echo "convert json to tsv for $FA"
  singularity exec --writable-tmpfs -e \
  -H ${tmp} \
  -B ${tmp}:${tmp} \
  ${DICEY_SIF} \
  python3 /opt/dicey/scripts/json2tsv.py \
  -m amplicon \
  -j ${tmp}/${FA}.json.gz > ${tmp}/${FA}.tsv

  echo "copying results to ${out}"
  mkdir -p ${out}/dicey/part/
  cp ${tmp}/${FA}.tsv ${out}/dicey/part/
  cp ${tmp}/${FA}.json.gz ${out}/dicey/part/

  echo "cleaning up temp"
  rm ${tmp}/${FA}*
done

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
drop table hits;
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
sqlite3 ${out}/envBarcodeMiner.results.sqlite '.separator "\t"' '.header on' ".import ${out}/dicey/dicey_results.acc.tsv hits"

sqlite3 ${out}/envBarcodeMiner.results.sqlite "
delete from trnL_hits where Chrom='Chrom';
"

echo "associate taxonomic information to dicey hits"
sqlite3 ${out}/envBarcodeMiner.results.sqlite "
ATTACH DATABASE ${db}/taxonomy_db.sqlite AS taxo;
drop table hits_taxid;
create table hits_taxid as
select
  h.Chrom || \"_\" || h.Id Id,
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
from trnL_hits_taxid
order by taxid
' > ${out}/dicey/hits.taxid.tsv

echo "Generate dicey hits lineage TSV report: hits.lineage.tsv"
echo -e "taxid\tacc\tlineage\tseq" > ${out}/dicey/hits.lineage.tsv
tmp_taxid=""
while IFS=$'\t' read -r taxid acc seq ; do
  if [ "$taxid" = "$tmp_taxid" ]; then
    echo "$taxid == $tmp_taxid --> ID=${tmp_id}"
    echo -e "$taxid\t$acc\t${lineage}_${tmp_id}\t$seq" >> ${out}/dicey/hits.lineage.tsv
  else
    tmp_id=1
    echo "$taxid != $tmp_taxid --> ID=${tmp_id}"
    tmp=$(
      for t in $(singularity exec --writable-tmpfs -e \
        -H ${tmp} \
        -B ${tmp}:${tmp} \
        ${DICEY_SIF} \
        perl /opt/taxdb/scripts/taxdb_query.pl --taxon $taxid --mode lineage ${out}/dicey/envBarcodeMiner.results.sqlite);
      do
        singularity exec --writable-tmpfs -e \
        -H ${tmp} \
        -B ${tmp}:${tmp} \
        ${DICEY_SIF} \
        perl /opt/taxdb/scripts/taxdb_query.pl --taxon ${t} ${out}/dicey/envBarcodeMiner.results.sqlite | grep -m 1 "scientific name";
      done | \
        cut -f 1-3,15,16 | \
        grep -P 'kingdom|phylum|class|order|family|genus|species' | \
        grep -vP '\tsuper\w+' | \
        grep -vP '\tsub\w+' | \
        grep -vP '\tno rank' | \
        sed "s/'/ /g" | cut -f 4 | perl -ne 'chomp($_); print $_ . ","'
    )

    lineage=$(
    perl -e "
    my \$tt = '$tmp';
    my @t = split(',',\$tt);
    my @rv = reverse(@t);
    my \$s = join(';',@rv);
    print \$s. \";$acc\" . \"\n\";
    "
    )
    echo -e "$taxid\t$acc\t${lineage}_${tmp_id}\t$seq" >> ${out}/dicey/hits.lineage.tsv
  fi

  tmp_taxid=$taxid
  tmp_id=$((tmp_id+1))
done < ${out}/dicey/hits.taxid.tsv

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
sqlite3 ${out}/envBarcodeMiner.results.sqlite '.separator "\t"' '.header on' ".import ${out}/dicey/hits.lineage.split.tsv hits_lineage"

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
from trnL_hits_lineage
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



rm ${tmp}/${FA}*
echo "done"
