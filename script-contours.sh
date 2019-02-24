#!/bin/bash
LOG="../../import-contours.log"
cd out/out_contours
for X in *.shp.gz; do
#~ X="contours_47-6.shp.gz"
	gunzip $X
	ogr2ogr -explodecollections -a_srs epsg:3857 -append -f "PostgreSQL" 'PG:dbname='contours2''  -nln contours -lco DIM=2 ${X%.*}
	gzip ${X%.*}
    echo $(date)' '$X' done'>> $LOG
done
echo $(date) 'analyse'>> $LOG
echo "VACUUM ANALYSE;" | psql -d contours2
echo $(date)' '$X' done'>> $LOG
echo 'DONE'>> $LOG


exit 0
