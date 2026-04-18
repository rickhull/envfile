#!/bin/sh

set -eu

BASE=1200 # debian-testing
ID=2200   # debian-unstable
HOSTNAME="debian-unstable"
DESCRIPTION="debian sid with non-free repos and ruby 3.3"
COMPONENTS="main contrib non-free non-free-firmware"
DEBIAN="deb http://deb.debian.org/debian"
SOURCES="$DEBIAN unstable $COMPONENTS"
TMP=/tmp/unstable.list

# clone testing template
pct clone $BASE $ID --description "$DESCRIPTION" --hostname $HOSTNAME
pct start $ID

# switch to unstable
echo "$SOURCES" > $TMP
pct push $ID $TMP /etc/apt/sources.list --perms 644

# update, upgrade
pct exec $ID -- sh -ceu \
    "apt update -y;
     apt full-upgrade -y"

# shutdown, create template
pct shutdown $ID
pct template $ID

# dump to template cache
dumpdir=/var/lib/vz/template/cache
vzdump $ID --mode stop --compress gzip --dumpdir $dumpdir

# rename to debian-unstable.tar.gz
dumpname=vzdump-lxc-$ID
dumpfile=$(ls $dumpdir/$dumpname*.gz | tail -n1)
if [ -e "$dumpfile" ]; then
    newname=/var/lib/vz/template/cache/debian-unstable.tar.gz
    mv "$dumpfile" $newname
    echo moved "$dumpfile" to $newname
else
    echo cannot find $dumpname in $dumpdir
    exit 1
fi
