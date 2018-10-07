#!/bin/bash

##
# Run OpenStreetMap tile server operations
#

# Command prefix that runs the command as the web user
asweb="setuser www-data"
HOME=/root

switch_to_python3 () {
    #cd $HOME
    #pip3 install virtualenvwrapper
    #export WORKON_HOME=$HOME/.virtualenvs
    #export PROJECT_HOME=$HOME/Devel
    #source /usr/local/bin/virtualenvwrapper.sh
    #mkvirtualenv virtualenv_python3
    rm -f /usr/bin/python && ln -s /usr/bin/python3 /usr/bin/python
}

die () {
    msg=$1
    echo "FATAL ERROR: " msg > 2
    exit
}

_startservice () {
    sv start $1 || die "Could not start $1"
}

startdb () {
    mkdir -p /var/run/postgresql/9.5-main.pg_stat_tmp
    _startservice postgresql
}

initdb () {
    echo "Initialising postgresql"
    if [ -d /var/lib/postgresql/9.5/main ] && [ $( ls -A /var/lib/postgresql/9.5/main | wc -c ) -ge 0 ]
    then
        die "Initialisation failed: the directory is not empty: /var/lib/postgresql/9.5/main"
    fi

    mkdir -p /var/lib/postgresql/9.5/main && chown -R postgres /var/lib/postgresql/ && chmod 0700 /var/lib/postgresql/9.5/main
    sudo -u postgres -i /usr/lib/postgresql/9.5/bin/initdb --pgdata /var/lib/postgresql/9.5/main
    ln -s /etc/ssl/certs/ssl-cert-snakeoil.pem /var/lib/postgresql/9.5/main/server.crt
    ln -s /etc/ssl/private/ssl-cert-snakeoil.key /var/lib/postgresql/9.5/main/server.key

    startdb
    createuser
    createdb
}

createuser () {
    USER=www-data
    echo "Creating user $USER"
    setuser postgres createuser -s $USER
}

createdb () {
    dbname=gis
    echo "Creating database $dbname"
    cd /var/www

    # Create the database
    setuser postgres createdb -O www-data $dbname

    # Install the Postgis schema
    $asweb psql -d $dbname -f /usr/share/postgresql/9.5/contrib/postgis-2.2/postgis.sql

    $asweb psql -d $dbname -c 'CREATE EXTENSION HSTORE;CREATE EXTENSION postgis'

    # Set the correct table ownership
    $asweb psql -d $dbname -c 'ALTER TABLE geometry_columns OWNER TO "www-data"; ALTER TABLE spatial_ref_sys OWNER TO "www-data";'

    # Add Spatial Reference Systems from PostGIS
    $asweb psql -d $dbname -f /usr/share/postgresql/9.5/contrib/postgis-2.2/spatial_ref_sys.sql
}

process_opentopomap_data () {

    # Get the generalized water polygons from http://openstreetmapdata.com/:
    cd /data
    wget http://data.openstreetmapdata.com/water-polygons-generalized-3857.zip
    wget http://data.openstreetmapdata.com/water-polygons-split-3857.zip
    unzip water-polygons-generalized-3857.zip
    unzip water-polygons-split-3857.zip
    rm *.zip


    #Download all SRTM tiles you need
    mkdir /data/srtm
    cd /data/srtm
    import=${SRTM_LIST_FILE:-$( ls -1t /tmp/srtm_list.txt 2>/dev/null | head -1 )}
    test -n "${import}" || \
        die "No import file list present: expected specification via SRTM_LIST_FILE or existence of /tmp/srtm_list.txt"

    echo "Downloading ${import} "
    wget -i ${import}

    # Unpack all zip files
    for zipfile in *.zip;do unzip -j -o "$zipfile" -d unpacked; done
    rm *.zip

    # Fill all voids
    cd unpacked
    for hgtfile in *.hgt;do gdal_fillnodata.py $hgtfile $hgtfile.tif; done

    #Merge all .tifs into one huge tif. This file is the raw DEM with full resolution and the start for any further steps. Don't delete raw.tif after these steps, you may use it for estimation of saddle directions.
    gdal_merge.py -n 32767 -co BIGTIFF=YES -co TILED=YES -co COMPRESS=LZW -co PREDICTOR=2 -o /data/raw.tif *.hgt.tif

    # Convert the raw file into Mercator projection, interpolate and shrink
    cd /data
    gdalwarp -co BIGTIFF=YES -co TILED=YES -co COMPRESS=LZW -co PREDICTOR=2 -t_srs "+proj=merc +ellps=sphere +R=6378137 +a=6378137 +units=m" -r bilinear -tr 1000 1000 raw.tif warp-1000.tif
    gdalwarp -co BIGTIFF=YES -co TILED=YES -co COMPRESS=LZW -co PREDICTOR=2 -t_srs "+proj=merc +ellps=sphere +R=6378137 +a=6378137 +units=m" -r bilinear -tr 5000 5000 raw.tif warp-5000.tif
    gdalwarp -co BIGTIFF=YES -co TILED=YES -co COMPRESS=LZW -co PREDICTOR=2 -t_srs "+proj=merc +ellps=sphere +R=6378137 +a=6378137 +units=m" -r bilinear -tr 500 500 raw.tif warp-500.tif
    gdalwarp -co BIGTIFF=YES -co TILED=YES -co COMPRESS=LZW -co PREDICTOR=2 -t_srs "+proj=merc +ellps=sphere +R=6378137 +a=6378137 +units=m" -r bilinear -tr 700 700 raw.tif warp-700.tif
    gdalwarp -co BIGTIFF=YES -co TILED=YES -co COMPRESS=LZW -co PREDICTOR=2 -t_srs "+proj=merc +ellps=sphere +R=6378137 +a=6378137 +units=m" -r bilinear -tr 90 90 raw.tif warp-90.tif

    # Create color relief for different zoom levels
    gdaldem color-relief -co COMPRESS=LZW -co PREDICTOR=2 -alpha warp-5000.tif /data/OpenTopoMap/mapnik/relief_color_text_file.txt relief-5000.tif
    gdaldem color-relief -co COMPRESS=LZW -co PREDICTOR=2 -alpha warp-500.tif /data/OpenTopoMap/mapnik/relief_color_text_file.txt relief-500.tif

    # Create hillshade for different zoom levels
    gdaldem hillshade -z 7 -compute_edges -co COMPRESS=JPEG warp-5000.tif hillshade-5000.tif
    gdaldem hillshade -z 7 -compute_edges -co BIGTIFF=YES -co TILED=YES -co COMPRESS=JPEG warp-1000.tif hillshade-1000.tif
    gdaldem hillshade -z 4 -compute_edges -co BIGTIFF=YES -co TILED=YES -co COMPRESS=JPEG warp-700.tif hillshade-700.tif
    gdaldem hillshade -z 2 -co compress=lzw -co predictor=2 -co bigtiff=yes -compute_edges warp-90.tif hillshade-90.tif && gdal_translate -co compress=JPEG -co bigtiff=yes -co tiled=yes hillshade-90.tif hillshade-90-jpeg.tif

}

build_contours () {

    switch_to_python3

    # Install phyghtmap
    cd /data
    # Create contour lines
    export HOME=/root
    phyghtmap --max-nodes-per-tile=0 -s 10 -0 --pbf warp-90.tif
    mv lon-*.osm.pbf contours.pbf
}

create_contours_db () {

    #build_contours
    build_contours

    dbname=contours
    # update postgre configuration
    echo 'local contours www-data peer' >> /etc/postgresql/9.5/main/pg_hba.conf

    startdb

    # load data with right style
    import="/data/contours.pbf"
    test -f ${import} || \
        die "No contours import file present: run build_contours before running create_contours_db"

    # Create contours database
    setuser postgres createdb -O www-data contours

    $asweb psql -d $dbname -c 'CREATE EXTENSION HSTORE;CREATE EXTENSION postgis'

    # Load contour file into database
    $asweb osm2pgsql --slim -d contours -C 12000 --number-processes 10 --style $HOME/OpenTopoMap/mapnik/osm2pgsql/contours.style ${import}

}

import_osm_data_with_opentopomap_style () {

    # load data with right style
    import=${OSM_IMPORT_FILE:-$( ls -1t /data/import.pbf /data/import.osm 2>/dev/null | head -1 )}
    test -n "${import}" || \
        die "No import file present: expected specification via OSM_IMPORT_FILE or existence of /data/import.osm or /data/import.pbf"

    echo "Importing ${import} into gis"
    $asweb osm2pgsql --slim -d gis -C 12000 --number-processes 10 --style $HOME/OpenTopoMap/mapnik/osm2pgsql/opentopomap.style ${import}

}

preprocess_opentopomap () {

    # Preprocessing
    cd $HOME/OpenTopoMap/mapnik/tools/
    cc -o saddledirection saddledirection.c -lm -lgdal
    cc -Wall -o isolation isolation.c -lgdal -lm -O2
    $asweb psql gis < arealabel.sql
    # update postgre configuration
    echo 'local lowzoom www-data peer' >> /etc/postgresql/9.5/main/pg_hba.conf
    echo 'local postgres www-data peer' >> /etc/postgresql/9.5/main/pg_hba.conf
    echo 'local template1 www-data peer' >> /etc/postgresql/9.5/main/pg_hba.conf
    $asweb ./update_lowzoom.sh

    sed -i 's/mapnik\/dem\/dem-srtm\.tiff/\/data\/raw\.tif/g' update_saddles.sh
    sed -i 's/mapnik\/dem\/dem-srtm\.tiff/\/data\/raw\.tif/g' update_isolations.sh

    $asweb ./update_saddles.sh
    $asweb ./update_isolations.sh

    $asweb psql gis < stationdirection.sql
    $asweb psql gis < viewpointdirection.sql
    $asweb psql gis < pitchicon.sql

    cd /data
    gdaldem hillshade -z 5 -compute_edges -co BIGTIFF=YES -co TILED=YES -co COMPRESS=JPEG warp-500.tif hillshade-500.tif
    gdaldem hillshade -z 5 -compute_edges -co BIGTIFF=YES -co TILED=YES -co COMPRESS=JPEG warp-90.tif hillshade-30m-jpeg.tif

    mkdir $HOME/OpenTopoMap/mapnik/dem
    cd $HOME/OpenTopoMap/mapnik/dem
    ln -s /data/*.tif .

}

configure_renderd_for_opentopomap () {

    sed -i 's/\/usr\/local\/src\/mapnik-style\/osm.xml/\/root\/OpenTopoMap\/mapnik\/opentopomap\.xml/g' /usr/local/etc/renderd.conf

}


import () {
    startdb
    # Assign from env var or find the most recent import.pbf or import.osm
    import=${OSM_IMPORT_FILE:-$( ls -1t /data/import.pbf /data/import.osm 2>/dev/null | head -1 )}
    test -n "${import}" || \
        die "No import file present: expected specification via OSM_IMPORT_FILE or existence of /data/import.osm or /data/import.pbf"

    echo "Importing ${import} into gis"
    echo "$OSM_IMPORT_CACHE" | grep -P '^[0-9]+$' || \
        die "Unexpected cache type: expected an integer but found: ${OSM_IMPORT_CACHE}"

    number_processes=`nproc`

    # Limit to 8 to prevent overwhelming pg with connections
    if test $number_processes -ge 8
    then
        number_processes=8
    fi

    $asweb osm2pgsql --slim --hstore --cache $OSM_IMPORT_CACHE --database gis --number-processes $number_processes $import
}

# render tiles via render_list
render () {
    startdb
    _startservice renderd
    # wait for services to start
    sleep 10
    min_zoom=${OSM_MIN_ZOOM:-0}
    max_zoom=${OSM_MAX_ZOOM:-8}
    render_force_arg=$( [ "$OSM_RENDER_FORCE" != false ] && echo '--force' || echo '' )
    number_processes=${OSM_RENDER_THREADS:-`nproc`}
    # Limit to 8 to prevent overwhelming pg with connections
    if test $number_processes -ge 8
    then
        number_processes=8
    fi
    echo "Rendering OSM tiles"

    $asweb render_list $render_force_arg --all --min-zoom $min_zoom --max-zoom $max_zoom --num-threads $number_processes
}


dropdb () {
    echo "Dropping database"
    cd /var/www
    setuser postgres dropdb gis
}

cli () {
    echo "Running bash"
    cd /var/www
    exec bash
}

startservices () {
    startdb
    _startservice renderd
    _startservice apache2
}

startservices_opentopomap () {
    configure_renderd_for_opentopomap
    startservices
}

render_opentopomap () {
    configure_renderd_for_opentopomap
    render
}

startweb () {
    _startservice apache2
}

help () {
    cat /usr/local/share/doc/run/help.txt
    exit
}

# wait until 2 seconds after boot when runit will have started supervising the services.

sleep 2

# Execute the specified command sequence
for arg
do
    $arg;
done

# Unless there is a terminal attached don't exit, otherwise docker
# will also exit
if ! tty --silent
then
    # Wait forever (see
    # http://unix.stackexchange.com/questions/42901/how-to-do-nothing-forever-in-an-elegant-way).
    tail -f /dev/null
fi
