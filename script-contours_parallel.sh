#!/bin/bash
LOG="../../import-contours.log"
cd out/out_contours

import()
{
  X=$1
  gunzip $X
  ogr2ogr -explodecollections -a_srs epsg:3857 -append -f "PostgreSQL" 'PG:dbname='contours2''  -nln contours -lco DIM=2 ${X%.*}
  gzip ${X%.*}
  echo $(date)' '$X' done'>> $LOG
  #~ echo $X
  #~ sleep 2
}
#~ X="contours_47-6.shp.gz"
for X in *.shp.gz; 
do
  count=`jobs -p | wc -l`
  echo $count
  while [ `jobs -p | wc -l` -ge 3 ]
  do
	sleep 5
  done
  import $X &
done

echo $(date) 'analyse'>> $LOG
echo "VACUUM ANALYSE;" | psql -d contours2
echo $(date)' '$X' done'>> $LOG
echo 'DONE'>> $LOG


exit 0
#~ 
createdb -U mapnik contours2
psql -d contours2 -U mapnik  -f /usr/share/postgresql/9.1/contrib/postgis-2.0/postgis.sql
psql -d contours2 -U mapnik -f /usr/share/postgresql/9.1/contrib/postgis-2.0/spatial_ref_sys.sql

Note: projection not recognized: wkb_geometry | geometry(MultiLineString,900914) | 
SELECT UpdateGeometrySRID('contours','wkb_geometry',3857);
ogr2ogr -a_srs epsg:3857 -append -f "PostgreSQL" 'PG:dbname='contours2''  -nln contours -nlt MULTILINESTRING -lco DIM=2 ${X%.*}

#~ #echo "ALTER USER mapnik WITH PASSWORD 'mapnik';"  | psql -d contour # not usefull
#~ exit
#~ dropdb contours
#~ 
#~ # test:
#~ 457 GB
#~ select count(*) from contours where ST_intersects(way, ST_MakeEnvelope(-180,72,180,85));
#~ echo "select count(*) from contours where ST_intersects(way, ST_MakeEnvelope(-180,72,180,85));" | psql -d contours
#~ 
#~ 963GB
#~ echo "vacuum;" | psql -d contours
#~ # size of the db:
#~ cd /var/lib/postgresql/8.4/main/base
#~ du -sh *
#~ 
#~ shared_buffers = 256MB
#~ time shp2pgsql -a -g way N06E124 contours | psql -U mapnik -q contour
#~ real	6m45.981s
#~ user	1m0.400s
#~ sys	0m15.977s
#~ 
#~ shared_buffers = 4100MB
#~ sudo /etc/init.d/postgresql-8.4 restart
#~ # get the shmmax value from message
#~ sudo sysctl -w kernel.shmmax=4403486720 #(temporary)
#~ sudo nano /etc/sysctl.conf 
#~ kernel.shmmax=4403486720 #(permanent)
#~ sudo /etc/init.d/postgresql-8.4 restart
#~ time shp2pgsql -a -g way N06E124 contours | psql -U mapnik -q contour
#~ real	6m45.998s
#~ user	1m0.092s
#~ sys	0m16.669s
#~ => disk is the limiting factor?


#~ echo "ALTER TABLE contour ADD COLUMN contour3857 geometry(LINESTRING,3857);" | psql -d contours #(long 5h ??)
#~ echo "ALTER TABLE contour drop column contour3857;" | psql -d contours
#~ echo $(date) ": table dropped"
#~ echo "SELECT AddGeometryColumn ('contour','contour3857',3857,'LINESTRING',2, false);" | psql -d contours
#~ echo $(date) ": AddGeometryColumn done"
#~ echo "UPDATE contour SET contour3857=ST_Transform(wkb_geometry,3857);" | psql -d contours
#~ echo $(date) ": table updated"
echo "SELECT DropGeometryColumn ('contour','wkb_geometry');" | psql -d contours
echo $(date) ": DropGeometryColumn done"
#~ echo "CREATE INDEX contour3857_geom_idx ON contour USING gist (contour3857);" | psql -d contours pas nécessaire !
#~ echo date ": Index done"
echo "CREATE INDEX contours_idx ON contours USING gist (contours);" | psql -d contours2
