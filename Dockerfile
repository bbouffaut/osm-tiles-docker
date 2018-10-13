## -*- docker-image-name: "ncareol/osm-tiles" -*-

##
# The OpenStreetMap Tile Server
#
# This creates an image with containing the OpenStreetMap tile server stack as
# described at
# <http://switch2osm.org/serving-tiles/manually-building-a-tile-server-12-04/>.
#

FROM phusion/baseimage:latest
MAINTAINER Erik Johnson <ej@ucar.edu>


# Ensure `add-apt-repository` is present
RUN apt-get update -y
RUN apt-get install -y software-properties-common python-software-properties

RUN apt-get install -y libboost-dev libboost-filesystem-dev libboost-program-options-dev libboost-python-dev libboost-regex-dev libboost-system-dev libboost-thread-dev

# Install remaining dependencies
RUN apt-get install -y subversion git-core tar unzip wget bzip2 build-essential autoconf libtool libxml2-dev libgeos-dev libpq-dev libbz2-dev munin-node munin libprotobuf-c0-dev protobuf-c-compiler libfreetype6-dev libpng12-dev libtiff5-dev libicu-dev libgdal-dev libcairo-dev libcairomm-1.0-dev apache2 apache2-dev libagg-dev liblua5.2-dev ttf-unifont

RUN apt-get install -y autoconf apache2-dev libtool libxml2-dev libbz2-dev libgeos-dev libgeos++-dev libproj-dev gdal-bin libgdal1-dev sudo

# Install OpenTopoMap dependencies
RUN apt-get install -y python3-setuptools python3-matplotlib python3-bs4 python3-numpy python3-gdal python-gdal

# Install postgresql and postgis
RUN apt-get install -y postgresql postgresql-contrib postgis postgresql-9.5-postgis-2.2

# Install osm2pgsql
RUN cd /tmp && git clone git://github.com/openstreetmap/osm2pgsql.git && \
    cd /tmp/osm2pgsql && \
    git checkout 0.88.1 && \
    ./autogen.sh && \
    ./configure && \
    make && make install && \
    cd /tmp && rm -rf /tmp/osm2pgsql


# Install the Mapnik library
RUN apt-get install -y libmapnik3.0 libmapnik-dev mapnik-utils python-mapnik unifont

# Verify that Mapnik has been installed correctly
RUN python -c 'import mapnik'

# Install mod_tile and renderd
RUN cd /tmp && git clone git://github.com/openstreetmap/mod_tile.git && \
    cd /tmp/mod_tile && \
    ./autogen.sh && \
    ./configure && \
    make && \
    make install && \
    make install-mod_tile && \
    ldconfig && \
    cd /tmp && rm -rf /tmp/mod_tile

# Install phyghtmap (OpenTopoMap)
RUN cd /tmp && wget http://katze.tfiu.de/projects/phyghtmap/phyghtmap_2.20.orig.tar.gz && \
    tar -xvzf phyghtmap_2.20.orig.tar.gz && \
    rm *.gz && \
    cd phyghtmap-2.20 && \
    python3 setup.py install

# Install the Mapnik stylesheet
RUN cd /usr/local/src && svn co http://svn.openstreetmap.org/applications/rendering/mapnik mapnik-style

# Install the coastline data
RUN cd /usr/local/src/mapnik-style && ./get-coastlines.sh /usr/local/share

# Download OpenTopoMap data
RUN cd /root && git clone https://github.com/der-stefan/OpenTopoMap.git && chmod go+rx /root/ && ln -s /data /root/OpenTopoMap/mapnik/ && chown -R www-data OpenTopoMap

# Configure mapnik style-sheets
RUN cd /usr/local/src/mapnik-style/inc && cp fontset-settings.xml.inc.template fontset-settings.xml.inc
ADD datasource-settings.sed /tmp/
RUN cd /usr/local/src/mapnik-style/inc && sed --file /tmp/datasource-settings.sed  datasource-settings.xml.inc.template > datasource-settings.xml.inc
ADD settings.sed /tmp/
RUN cd /usr/local/src/mapnik-style/inc && sed --file /tmp/settings.sed  settings.xml.inc.template > settings.xml.inc

# Configure renderd
ADD renderd.conf /tmp/
RUN cd /usr/local/etc && mv /tmp/renderd.conf .

# Create the files required for the mod_tile system to run
RUN mkdir /var/run/renderd && chown www-data: /var/run/renderd
RUN mkdir /var/lib/mod_tile && chown www-data /var/lib/mod_tile

# Replace default apache index page with OpenLayers demo
ADD www/* /var/www/html/

# Configure mod_tile
ADD mod_tile.load /etc/apache2/mods-available/
ADD mod_tile.conf /etc/apache2/mods-available/
RUN a2enmod mod_tile

# Ensure the webserver user can connect to the gis database
RUN sed -i -e 's/local   all             all                                     peer/host all all 0\.0\.0\.0\/0 trust/' /etc/postgresql/9.5/main/pg_hba.conf

# Tune postgresql
ADD postgresql.conf.sed /tmp/
RUN sed --file /tmp/postgresql.conf.sed --in-place /etc/postgresql/9.5/main/postgresql.conf

# Define the application logging logic
ADD syslog-ng.conf /etc/syslog-ng/conf.d/local.conf
RUN rm -rf /var/log/postgresql

# Create a `postgresql` `runit` service
ADD postgresql /etc/sv/postgresql
RUN update-service --add /etc/sv/postgresql

# Create an `apache2` `runit` service
ADD apache2 /etc/sv/apache2
RUN update-service --add /etc/sv/apache2

# Create a `renderd` `runit` service
ADD renderd /etc/sv/renderd
RUN update-service --add /etc/sv/renderd

# Clean up APT when done
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Expose the webserver and database ports
EXPOSE 80 80

# We need the volume for importing data from
VOLUME ["/data"]

# Set the osm2pgsql import cache size in MB. Used in `run import`.
ENV OSM_IMPORT_CACHE 40

# Add the README
ADD README.md /usr/local/share/doc/

# Add the help file
RUN mkdir -p /usr/local/share/doc/run
ADD help.txt /usr/local/share/doc/run/help.txt

# Add the entrypoint
ADD run.sh /usr/local/sbin/run
ENTRYPOINT ["/sbin/my_init", "--", "/usr/local/sbin/run"]

# Default to showing the usage text
CMD ["help"]
