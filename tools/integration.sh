#!/bin/bash -xe
# Parameters:
# PBR_PIP_VERSION :- if not set, run pip's latest release, if set must be a
#    valid reference file entry describing what pip to use.
# WHEELHOUSE :- if not set, use a temporary wheelhouse, set to a specific path
#    to use an existing one.
# PIPFLAGS :- may be set to any pip global option for e.g. debugging.
# Bootstrappping the mkenv needs to install *a* pip
export PIPVERSION=pip
PIPFLAGS=${PIPFLAGS:-}

function mkvenv {
    venv=$1

    rm -rf $venv
    virtualenv -p python3 $venv
    $venv/bin/pip install $PIPFLAGS -U $PIPVERSION 'setuptools;python_version>="3.12"' wheel requests

    # If a change to PBR is being tested, preinstall the wheel for it
    if [ -n "$PBR_CHANGE" ] ; then
        $venv/bin/pip install $PIPFLAGS $pbrsdistdir/dist/pbr-*.whl
    fi
}

# BASE should be a directory with a subdir called "openstack" and in that
#      dir, there should be a git repository for every entry in PROJECTS
BASE=${BASE:-/home/zuul/src/opendev.org/}

REPODIR=${REPODIR:-$BASE/openstack}

# TODO: Figure out how to get this on to the box properly
sudo apt-get update
sudo apt-get install -y --force-yes libvirt-dev libxml2-dev libxslt-dev libmysqlclient-dev libpq-dev libnspr4-dev pkg-config libsqlite3-dev libffi-dev libldap2-dev libsasl2-dev ccache libkrb5-dev liberasurecode-dev libjpeg-dev libsystemd-dev libnss3-dev libssl-dev libpcre3-dev

# FOR pyyaml
sudo apt-get install -y --force-yes debhelper python3-all-dev python3-all-dbg libyaml-dev cython3 quilt

# And use ccache explitly
export PATH=/usr/lib/ccache:$PATH

tmpdir=$(mktemp -d)

# Set up a wheelhouse
export WHEELHOUSE=${WHEELHOUSE:-$tmpdir/.wheelhouse}
mkvenv $tmpdir/wheelhouse
# Specific PIP version - must succeed to be useful.
# - build/download a local wheel so we don't hit the network on each venv.
if [ -n "${PBR_PIP_VERSION:-}" ]; then
    td=$(mktemp -d)
    $tmpdir/wheelhouse/bin/pip wheel -w $td $PBR_PIP_VERSION
    # This version will now be installed in every new venv.
    export PIPVERSION="$td/$(ls $td)"
    $tmpdir/wheelhouse/bin/pip install -U $PIPVERSION
    # We have pip in global-requirements as open-ended requirements,
    # but since we don't use -U in any other invocations, our version
    # of pip should be sticky.
fi
# Build wheels for everything so we don't hit the network on each venv.
# Not all packages properly build wheels (httpretty for example).
# Do our best but ignore errors when making wheels.
set +e
$tmpdir/wheelhouse/bin/pip $PIPFLAGS wheel -w $WHEELHOUSE -f $WHEELHOUSE -r \
    $REPODIR/requirements/global-requirements.txt
set -e

#BRANCH
BRANCH=${OVERRIDE_ZUUL_BRANCH=:-master}
# PROJECTS is a list of projects that we're testing
PROJECTS=$*

pbrsdistdir=$tmpdir/pbrsdist
git clone $REPODIR/pbr $pbrsdistdir
cd $pbrsdistdir

# Prepare a wheel and flag whether a change to PBR is being tested
# TODO(clarkb) these ZUUL_* vars haven't been valid in quite some time
# we need to find another way to check if we are in a PBR_CHANGE
# context.
if git fetch $ZUUL_URL/$ZUUL_PROJECT $ZUUL_REF ; then
    mkvenv wheel
    wheel/bin/python setup.py bdist_wheel
    PBR_CHANGE=1
fi

eptest=$tmpdir/eptest
mkdir $eptest
cd $eptest

cat <<EOF > setup.cfg
[metadata]
name = test_project

[entry_points]
console_scripts =
    test_cmd = test_project:main
EOF

cat <<EOF > setup.py
import setuptools

from requests import Timeout
from socket import error as SocketError

# Some environments have network issues that drop connections to pypi
# when running integration tests, so we retry here so that hour-long
# test runs are less likely to fail randomly.
try:
    setuptools.setup(
        setup_requires=['pbr'],
        pbr=True,
    )
except (SocketError, Timeout):
    setuptools.setup(
        setup_requires=['pbr'],
        pbr=True,
    )
EOF

mkdir test_project
cat <<EOF > test_project/__init__.py
def main():
    print("Test cmd")
EOF

epvenv=$eptest/venv
mkvenv $epvenv

eppbrdir=$tmpdir/eppbrdir
git clone $REPODIR/pbr $eppbrdir
$epvenv/bin/pip $PIPFLAGS install -f $WHEELHOUSE -e $eppbrdir

# First check develop
PBR_VERSION=0.0 $epvenv/bin/python setup.py develop
cat $epvenv/bin/test_cmd
grep 'PBR Generated' $epvenv/bin/test_cmd
PBR_VERSION=0.0 $epvenv/bin/python setup.py develop --uninstall

# Now check install
PBR_VERSION=0.0 $epvenv/bin/python setup.py install
cat $epvenv/bin/test_cmd
grep 'PBR Generated' $epvenv/bin/test_cmd
$epvenv/bin/test_cmd | grep 'Test cmd'

projectdir=$tmpdir/projects
mkdir -p $projectdir
sudo chown -R $USER $REPODIR

export PBR_INTEGRATION=1
export PIPFLAGS
export PIPVERSION
PBRVERSION=pbr
if [ -n "$PBR_CHANGE" ] ; then
    PBRVERSION=$(ls $pbrsdistdir/dist/pbr-*.whl)
fi
export PBRVERSION
export PROJECTS
export REPODIR
export WHEELHOUSE
export OS_TEST_TIMEOUT=1200
cd $REPODIR/pbr
mkvenv .venv
source .venv/bin/activate
pip install -r test-requirements.txt
pip install ${REPODIR}/requirements
stestr run --suppress-attachments test_integration
