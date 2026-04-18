#!/bin/sh

set -eu

BASE=200 # debian-stable
ID=1200  # debian-testing
HOSTNAME="debian-testing"
DESCRIPTION="debian testing with non-free repos and ruby 3.3"
COMPONENTS="main contrib non-free non-free-firmware"
DEBIAN="deb http://deb.debian.org/debian"
SOURCES="$DEBIAN testing $COMPONENTS"
DEBS="ruby3.3"
TMP=/tmp/testing.list

# clone stable template
pct clone $BASE $ID --description "$DESCRIPTION" --hostname $HOSTNAME
pct start $ID

# switch from stable (bookworm) to testing
echo "$SOURCES" > $TMP
pct push $ID $TMP /etc/apt/sources.list --perms 644

# update, upgrade, install ruby
pct exec $ID -- sh -ceu \
    "export DEBIAN_FRONTENT=noninteractive;
     apt update -y;
     apt full-upgrade -y;
     apt install -y $DEBS"

# shutdown, create template
pct shutdown $ID
pct template $ID

# dump to template cache
dumpdir=/var/lib/vz/template/cache
vzdump $ID --mode stop --compress gzip --dumpdir $dumpdir

# rename to devbox.tar.gz
dumpname=vzdump-lxc-$ID
dumpfile=$(ls $dumpdir/$dumpname*.gz | tail -n1)
if [ -e "$dumpfile" ]; then
    newname=$dumpdir/$HOSTNAME.tar.gz
    mv "$dumpfile" $newname
    echo moved "$dumpfile" to $newname
else
    echo cannot find $dumpname in $dumpdir
    exit 1
fi
