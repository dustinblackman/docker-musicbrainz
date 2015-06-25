#!/bin/bash

# Set the locale
locale-gen en_US.UTF-8

# Fix a Debianism of the nobody's uid being 65534
usermod -u 99 nobody
usermod -g 100 nobody

# update apt and install wget
apt-get update -qq
apt-get install -y wget

# add postgresql repo
wget -O - http://apt.postgresql.org/pub/repos/apt/ACCC4CF8.asc | apt-key add -
echo "deb http://apt.postgresql.org/pub/repos/apt/ trusty-pgdg main" > /etc/apt/sources.list.d/pgdg.list

# update apt again and install postgresql
apt-get update -qq
apt-get install \
postgresql-client-9.4 \
postgresql-9.4 \
postgresql-server-dev-9.4 \
postgresql-contrib-9.4 \
postgresql-plperl-9.4 \

# install git-core, memcached and redis-server
git-core \
memcached \
redis-server \

# install nodejs and npm
nodejs \
npm \
nodejs-legacy \

# install build essential and supervisor
apt-get install \
build-essential \
supervisor \

# install perl dependencies
python-software-properties \
software-properties-common \
libxml2-dev \
libpq-dev \
libexpat1-dev \
libdb-dev \
libicu-dev \
liblocal-lib-perl \
cpanminus \
# install libjson
libjson-xs-perl -y

# fetch source from git
cd /opt
git clone --recursive git://github.com/metabrainz/musicbrainz-server.git musicbrainz
cd /opt/musicbrainz

# enable local::lib
echo 'eval $( perl -Mlocal::lib )' >> ~/.bashrc
source ~/.bashrc

# install packages
cpanm --installdeps --notest .
cpanm SARTAK/MooseX-Role-Parameterized-1.02.tar.gz
cpanm MooseX::Singleton
cpanm Term::Size

# install node dependencies
npm install
./node_modules/.bin/gulp

# install musicbrainz postgres extensions
cd postgresql-musicbrainz-unaccent
make
make install
cd ..

cd postgresql-musicbrainz-collate
make
make install
cd ..

# fix postgres permissions
echo "local   all    all    trust" >> /etc/postgresql/9.4/main/pg_hba.conf
echo "host all  all    0.0.0.0/0  md5" >> /etc/postgresql/9.4/main/pg_hba.conf
echo "listen_addresses='*'" >> /etc/postgresql/9.4/main/postgresql.conf


# fix crontab entry
cat <<'EOT' > /root/cronjob
0,59 * * * *     /bin/bash  /root/update-script.sh
EOT

# fix cron script

cat <<'EOT' > /root/update-script.sh
#!/bin/bash
UPDATER_LOG_DIR=/config/updater-logs
mkdir -p $UPDATER_LOG_DIR
touch $UPDATER_LOG_DIR/slave.log
cd /opt/musicbrainz
eval `./admin/ShowDBDefs`
X=${SLAVE_LOG:=$UPDATER_LOG_DIR/slave.log}
X=${LOGROTATE:=/usr/sbin/logrotate --state $UPDATER_LOG_DIR/.logrotate-state}
./admin/replication/LoadReplicationChanges >> $SLAVE_LOG 2>&1 || {
    RC=$?
    echo `date`" : LoadReplicationChanges failed (rc=$RC) - see $SLAVE_LOG"
}

$LOGROTATE /dev/stdin <<EOF
$SLAVE_LOG {
    daily
    rotate 30
}
EOF

# eof
EOT

chmod +x /root/update-script.sh

# fix startup files

# fix time
cat <<'EOT' > /etc/my_init.d/001-fix-the-time.sh
#!/bin/bash
if [[ $(cat /etc/timezone) != $TZ ]] ; then
  echo "$TZ" > /etc/timezone
 exec  dpkg-reconfigure -f noninteractive tzdata
fi
EOT

# set DBDefs.pm file

cat <<'EOT' > /etc/my_init.d/002-configure-DBDefs.sh
#!/bin/bash
# sanitize brainzcode for white space
SANEDBRAINZCODE0=$BRAINZCODE
SANEDBRAINZCODE1="${SANEDBRAINZCODE0#"${SANEDBRAINZCODE0%%[![:space:]]*}"}"
SANEDBRAINZCODE="${SANEDBRAINZCODE1%"${SANEDBRAINZCODE1##*[![:space:]]}"}"
if [ -f "/config/DBDefs.pm" ]; then
echo "DBDefs is in your config folder, may need editing"
else
cp /root/DBDefs.pm /config/DBDefs.pm
fi
sed -i "s|\(sub REPLICATION_ACCESS_TOKEN\ {\ \\\"\)[^<>]*\(\\\"\ }\)|\1${SANEDBRAINZCODE}\2|" /config/DBDefs.pm
cp /config/DBDefs.pm /opt/musicbrainz/lib/DBDefs.pm
chown nobody:users /config/DBDefs.pm
EOT

# postgres initialisation, start postgres and redis-server

cat <<'EOT' > /etc/my_init.d/003-postgres-initialise.sh
#!/bin/bash
 if [ -f "/data/main/postmaster.opts" ]; then
echo "postgres folders appear to be set"
/usr/bin/supervisord -c /root/supervisord.conf &
sleep 10s
else
cp /etc/postgresql/9.4/main/postgresql.conf /data/postgresql.conf
cp /etc/postgresql/9.4/main/pg_hba.conf /data/pg_hba.conf
sed -i '/^data_directory*/ s|/var/lib/postgresql/9.4/main|/data/main|' /data/postgresql.conf
sed -i '/^hba_file*/ s|/etc/postgresql/9.4/main/pg_hba.conf|/data/pg_hba.conf|' /data/postgresql.conf
echo "hot_standby = on" >> /data/postgresql.conf
mkdir -p /data/main
chown postgres:postgres /data/*
chmod 700 /data/main
/sbin/setuser postgres /usr/lib/postgresql/9.4/bin/initdb -D /data/main
sleep 5s
/usr/bin/supervisord -c /root/supervisord.conf &
sleep 10s
/sbin/setuser postgres psql --command="CREATE USER musicbrainz WITH SUPERUSER PASSWORD 'musicbrainz';" >/dev/null 2>&1
sleep 5s
echo "BEGINNING INITIAL DATABASE IMPORT ROUTINE, THIS COULD TAKE SEVERAL HOURS AND THE DOCKER MAY LOOK UNRESPONSIVE"
echo "DO NOT STOP DOCKER UNTIL IT IS COMPLETED"
echo "-- Cleaning Import Folder"
mkdir -p /data/import
rm -rf /data/import/*
echo "-- Checking for Latest Version of Dump"
wget -nd -nH -P /data/import ftp://ftp.musicbrainz.org/pub/musicbrainz/data/fullexport/LATEST > /dev/null 2>&1
LATEST=$(cat /data/import/LATEST)
echo "-- Downloading Latest Dump"
wget -r --no-parent -nd -nH -P /data/import --reject "index.html*, mbdump-edit.*, mbdump-documentation*" "ftp://ftp.musicbrainz.org/pub/musicbrainz/data/fullexport/$LATEST"
pushd /data/import && md5sum -c MD5SUMS && popd
cd /opt/musicbrainz
echo "-- Restoring Database"
./admin/InitDb.pl --createdb --import /data/import/mbdump*.tar.bz2 --tmp-dir /data/import --echo
echo "IMPORT IS COMPLETE, MOVING TO NEXT PHASE"
fi
EOT

# main import and or run musicbrainz

cat <<'EOT' > /etc/my_init.d/004-import-databases--and-or-run-everything.sh
#!/bin/bash
crontab /root/cronjob
cd /opt/musicbrainz
echo "- STARTING MusicBrainz"
plackup -Ilib -r
EOT


# fix supervisord.conf file

cat <<'EOT' > /root/supervisord.conf
[supervisord]
nodaemon=true
[program:postgres]
user=postgres
command=/usr/lib/postgresql/9.4/bin/postgres -D /data/main -c config_file=/data/main/postgresql.conf
[program:redis-server]
user=root
command=redis-server
EOT
