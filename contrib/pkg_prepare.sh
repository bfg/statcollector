#
# This is just a shell include file
#

die() {
	echo -e "FATAL: $@"
	exit 1
}

pkg_prepare_statcollector() {
	local BASEDIR="${1}"
	local PKG="${2}"
	test -z "${BASEDIR}" -o ! -d "${BASEDIR}" && die "Invalid basedir: '$BASEDIR'"
	test -z "${PKG}" -o ! -d "${PKG}" && die "Invalid pkgdir: '$PKG'"
	local pd=`pwd`

	# enter pkg
	cd "${PKG}" || die "Unable to enter dir: $PKG"

	# create directories
	mkdir -p usr/{s,}bin usr/lib/statcollector || die "Unable to create skeleton directories."

	# copy binaries...
	cp -a "${BASEDIR}/bin/statcollector.pl" usr/sbin || die "Unable to install binariy: stat-collector.pl."
	
	# copy libzzz...
	mkdir -p usr/lib/statcollector/ACME/TC/Agent/Plugin || die "Unable to create statcollector lib directory."
	cp -ra ${BASEDIR}/lib/ACME/TC/Agent/Plugin/StatCollector* usr/lib/statcollector/ACME/TC/Agent/Plugin || die "Unable to install statcollector libraries." 

	cd "$pd"
	return 0
}

pkg_prepare_statcollector_agent() {
	local BASEDIR="${1}"
	local PKG="${2}"
	test -z "${BASEDIR}" -o ! -d "${BASEDIR}" && die "Invalid basedir: '$BASEDIR'"
	test -z "${PKG}" -o ! -d "${PKG}" && die "Invalid pkgdir: '$PKG'"
	local pd=`pwd`
	
	# enter pkg
	cd "${PKG}" || die "Unable to enter dir: $PKG"

	# create directories
	mkdir -p usr/sbin usr/lib/statcollector || die "Unable to create skeleton directories."

	# copy binaries...
	cp -a "${BASEDIR}/bin/statcollector-agent.pl" usr/sbin || die "Unable to install binaries."
	
	# copy libzzz...
	cp -ar ${BASEDIR}/lib/* usr/lib/statcollector || die "Unable to install libraries."
	
	cd "$pd"
	return 0
}

pkg_create_debian() {
	local PKG="$1"
	test -z "${PKG}" -o ! -d "${PKG}" && die "Invalid pkgdir: '$PKG'"

	# fix debian control file
	perl -pi -e "s/\\\${PACKAGE}/${PACKAGE_NAME}/g" "${PKG}/DEBIAN/control" || die "Unable to set DEBIAN/control package name."
	perl -pi -e "s/\\\${VERSION}/${PACKAGE_VERSION}/g" "${PKG}/DEBIAN/control" || die "Unable to set DEBIAN/control package version."

	# create debian package
	#echo "Creating DEBIAN package."
	dpkg --build "${PKG}" /tmp || die "Unable to create debian package."
	echo "Package dropped in /tmp"	
}

pkg_create_slackware() {
	true
}

# EOF
