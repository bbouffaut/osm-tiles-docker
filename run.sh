#!/bin/sh

##
# Run OpenStreetMap tile server operations
#

# Command prefix that runs the command as the web user
asweb="setuser www-data"

die () {
    msg=$1
    echo "FATAL ERROR: " msg > 2
    exit
}

_startservice () {
    sv start $1 || die "Could not start $1"
}

startdb () {
    _startservice postgresql
}

initdb () {
    echo "Initialising postgresql"
    if [ -d /var/lib/postgresql/9.3/main ] && [ $( ls -A /var/lib/postgresql/9.3/main | wc -c ) -ge 0 ]
    then
        die "Initialisation failed: the directory is not empty: /var/lib/postgresql/9.3/main"
    fi

    mkdir -p /var/lib/postgresql/9.3/main && chown -R postgres /var/lib/postgresql/
    sudo -u postgres -i /usr/lib/postgresql/9.3/bin/initdb --pgdata /var/lib/postgresql/9.3/main
    ln -s /etc/ssl/certs/ssl-cert-snakeoil.pem /var/lib/postgresql/9.3/main/server.crt
    ln -s /etc/ssl/private/ssl-cert-snakeoil.key /var/lib/postgresql/9.3/main/server.key

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
    $asweb psql -d $dbname -f /usr/share/postgresql/9.3/contrib/postgis-2.1/postgis.sql

    $asweb psql -d $dbname -c 'CREATE EXTENSION HSTORE;'

    # Set the correct table ownership
    $asweb psql -d $dbname -c 'ALTER TABLE geometry_columns OWNER TO "www-data"; ALTER TABLE spatial_ref_sys OWNER TO "www-data";'

    # Add Spatial Reference Systems from PostGIS
    $asweb psql -d $dbname -f /usr/share/postgresql/9.3/contrib/postgis-2.1/spatial_ref_sys.sql
}

process_opentopomap_data() {
    # Download OpenTopoMap data
    cd ~
    git clone https://github.com/der-stefan/OpenTopoMap.git

    # Get the generalized water polygons from http://openstreetmapdata.com/:
    cd /data
    wget http://data.openstreetmapdata.com/water-polygons-generalized-3857.zip
    wget http://data.openstreetmapdata.com/water-polygons-split-3857.zip
    unzip water-polygons-generalized-3857.zip
    unzip water-polygons-split-3857.zip

    # Install phyghtmap
    mkdir ~/src
    cd ~/src
    wget http://katze.tfiu.de/projects/phyghtmap/phyghtmap_2.10.orig.tar.gz
    tar -xvzf phyghtmap_2.10.orig.tar.gz
    cd phyghtmap-2.10
    python3 setup.py install

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
    gdaldem color-relief -co COMPRESS=LZW -co PREDICTOR=2 -alpha warp-5000.tif ~/OpenTopoMap/mapnik/relief_color_text_file.txt relief-5000.tif
    gdaldem color-relief -co COMPRESS=LZW -co PREDICTOR=2 -alpha warp-500.tif ~/OpenTopoMap/mapnik/relief_color_text_file.txt relief-500.tif

    # Create hillshade for different zoom levels
    gdaldem hillshade -z 7 -compute_edges -co COMPRESS=JPEG warp-5000.tif hillshade-5000.tif
    gdaldem hillshade -z 7 -compute_edges -co BIGTIFF=YES -co TILED=YES -co COMPRESS=JPEG warp-1000.tif hillshade-1000.tif
    gdaldem hillshade -z 4 -compute_edges -co BIGTIFF=YES -co TILED=YES -co COMPRESS=JPEG warp-700.tif hillshade-700.tif
    gdaldem hillshade -z 2 -co compress=lzw -co predictor=2 -co bigtiff=yes -compute_edges warp-90.tif hillshade-90.tif && gdal_translate -co compress=JPEG -co bigtiff=yes -co tiled=yes hillshade-90.tif hillshade-90-jpeg.tif

    # Create contour lines
    phyghtmap --max-nodes-per-tile=0 -s 10 -0 --pbf warp-90.tif
    mv lon-*.osm.pbf contours.pbf

}

create_contours_db() {

    # Create contours database
    setuser postgres createdb -O www-data contours
    $asweb postgres psql -d contours -c 'CREATE EXTENSION postgis;'

    # Load contour file into database
    $asweb osm2pgsql --slim -d contours -C 12000 --number-processes 10 --style ~/OpenTopoMap/mapnik/osm2pgsql/contours.style /data/contours.pbf

}

import_osm_data_with_right_style() {

    # load data with right style
    import=${OSM_IMPORT_FILE:-$( ls -1t /data/import.pbf /data/import.osm 2>/dev/null | head -1 )}
    test -n "${import}" || \
        die "No import file present: expected specification via OSM_IMPORT_FILE or existence of /data/import.osm or /data/import.pbf"

    echo "Importing ${import} into gis"
    $asweb osm2pgsql --slim -d gis -C 12000 --number-processes 10 --style ~/OpenTopoMap/mapnik/osm2pgsql/opentopomap.style ${import}

}

preprocess_opentopomap() {

    # Preprocessing
    cd ~/OpenTopoMap/mapnik/tools/
    cc -o saddledirection saddledirection.c -lm -lgdal
    cc -Wall -o isolation isolation.c -lgdal -lm -O2
    $asweb psql gis < arealabel.sql
    ./update_lowzoom.sh

    sed -i 's/mapnik\/dem\/dem-srtm\.tiff/\/data\/raw\.tif/g' update_saddles.sh
    sed -i 's/mapnik\/dem\/dem-srtm\.tiff/\/data\/raw\.tif/g' update_isolations.sh

    ./update_saddles.sh
    ./update_isolations.sh

    $asweb psql gis < stationdirection.sql
    $asweb psql gis < viewpointdirection.sql
    $asweb psql gis < pitchicon.sql

}

configure_renderd_for_opentopomap() {

    cp ~/OpenTopoMap/mapnik/opentopomap.xml /usr/local/src/mapnik-style/osm.xml

    cd /data
    gdaldem hillshade -z 5 -compute_edges -co BIGTIFF=YES -co TILED=YES -co COMPRESS=JPEG warp-500.tif hillshade-500.tif
    gdaldem hillshade -z 5 -compute_edges -co BIGTIFF=YES -co TILED=YES -co COMPRESS=JPEG warp-90.tif hillshade-30m-jpeg.tif

    mkdir ~/OpenTopoMap/mapnik/dem
    cd ~/OpenTopoMap/mapnik/dem
    ln -s /data/*.tif .

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
