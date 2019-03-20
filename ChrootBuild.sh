#!/bin/bash
# shellcheck disable=SC2005,SC2001,SC2181
#
# Install minimal RPM-set into chroot
#
#####################################
PROGNAME=$(basename "$0")
CHROOT="${CHROOT:-/mnt/ec2-root}"
if [[ $(rpm --quiet -q redhat-release-server)$? -eq 0 ]]
then
   OSREPOS=(
      rhui-REGION-client-config-server-7
      rhui-REGION-rhel-server-releases
      rhui-REGION-rhel-server-rh-common
      rhui-REGION-rhel-server-optional
      rhui-REGION-rhel-server-extras
   )
elif [[ $(rpm --quiet -q centos-release)$? -eq 0 ]]
then
   OSREPOS=(
      os
      base
      updates
      extras
   )
fi
DEFAULTREPOS=$(printf ",%s" "${OSREPOS[@]}" | sed 's/^,//')
FIPSDISABLE="${FIPSDISABLE:-UNDEF}"
YCM="/bin/yum-config-manager"

function PrepChroot() {
   local REPOPKGS=($(echo \
                     "$(rpm --qf '%{name}\n' -qf /etc/redhat-release)" ; \
                     echo "$(rpm --qf '%{name}\n' -qf \
                            /etc/yum.repos.d/* 2>&1 | \
                            grep -v "not owned" | sort -u)" ; \
                     echo yum-utils coreutils elfutils-libelf
                   ))

   # Enable DNS resolution in the chroot
   if [[ ! -e ${CHROOT}/etc/resolv.conf ]]
   then
      install -m 0644 /etc/resolv.conf "${CHROOT}/etc"
   fi

   # Do this so that install of chkconfig RPM succeeds
   if [[ ! -e ${CHROOT}/etc/init.d ]]
   then
      ln -t "${CHROOT}/etc" -s ./rc.d/init.d
   fi
   if [[ ! -e ${CHROOT}/etc/rc.d/init.d ]]
   then
      install -d -m 0755 "${CHROOT}/etc/rc.d/init.d"
   fi

   yumdownloader --destdir=/tmp "${REPOPKGS[@]}"
   rpm --root "${CHROOT}" --initdb
   rpm --root "${CHROOT}" -ivh --nodeps /tmp/*.rpm

   # When we don't specify repos, default to a sensible value-list
   if [[ -z ${BONUSREPO+xxx} ]]
   then
      BONUSREPO=${DEFAULTREPOS}
   fi

   yum --disablerepo="*" --enablerepo="${BONUSREPO}" \
      --installroot="${CHROOT}" -y reinstall "${REPOPKGS[@]}"
   yum --disablerepo="*" --enablerepo="${BONUSREPO}" \
      --installroot="${CHROOT}" -y install yum-utils

   # if alt-repo defined, disable everything, then install alt-repos
   if [[ ! -z ${REPORPMS+xxx} ]]
   then
      for RPM in "${REPORPMS[@]}"
      do
         { STDERR=$(rpm --root "${CHROOT}" -ivh --nodeps "${RPM}" 2>&1 1>&$out); } {out}>&1 || echo "$STDERR" | grep "is already installed"
      done
   fi
}


######################
## Main program flow
######################

# See if we'e passed any valid flags
OPTIONBUFR=$(getopt -o r:b:e: --long repouri:bonusrepos:extras: -n "${PROGNAME}" -- "$@")
eval set -- "${OPTIONBUFR}"

while true
do
   case "$1" in
      -r|--repouri)
         case "$2" in
	    "")
	       echo "Error: option required but not specified" > /dev/stderr
	       shift 2;
	       exit 1
	       ;;
	    *)
	       REPORPMS=($(echo "${2}" | sed 's/,/ /g'))
	       shift 2;
	       ;;
	 esac
	 ;;
      -b|--bonusrepos)
         case "$2" in
	    "")
	       echo "Error: option required but not specified" > /dev/stderr
	       shift 2;
	       exit 1
	       ;;
	    *)
	       BONUSREPO=${2}
	       shift 2;
	       ;;
	 esac
	 ;;
      -e|--extras)
         case "$2" in
	    "")
	       echo "Error: option required but not specified" > /dev/stderr
	       shift 2;
	       exit 1
	       ;;
	    *)
	       EXTRARPMS=($(echo "${2}" | sed 's/,/ /g'))
	       shift 2;
	       ;;
	 esac
	 ;;
      --)
         shift
	 break
	 ;;
      *)
         echo "Internal error!" > /dev/stderr
	 exit 1
	 ;;
   esac
done

# Stage useable repo-defs into $CHROOT/etc/yum.repos.d
PrepChroot

if [[ ! -z ${BONUSREPO+xxx} ]]
then
   ENABREPO=--enablerepo=${BONUSREPO}
   # shellcheck disable=SC2125
   YUMDO="yum --nogpgcheck --installroot=${CHROOT} --disablerepo="*" ${ENABREPO} install -y"
else
   YUMDO="yum --nogpgcheck --installroot=${CHROOT} install -y"
fi

# Activate repos in the chroot...
chroot "$CHROOT" "${YCM}" --disable "*"
chroot "$CHROOT" "${YCM}" --enable "${BONUSREPO}"

# symlink run to var/run
if [[ $(rpm --quiet -q redhat-release-server)$? -eq 0 ]]
then
    /bin/cp -rp "${CHROOT}"/var/run/* "${CHROOT}"/run && /bin/rm -rf "${CHROOT}"/var/run/* && /bin/rm -rf "${CHROOT}"/var/run
    chroot "${CHROOT}" /bin/ln -s ../run /var
fi

# Whether to include FIPS kernel modules...
case "${FIPSDISABLE}" in
   true|TRUE|1|on)
      FIPSRPM=''
      ;;
   UNDEF|''|false|FALSE|0)
      FIPSRPM='dracut-fips'
      ;;
esac

# Setup the "include" package list
INCLUDE_PKGS=($(yum groupinfo core 2>&1 | sed -n '/Mandatory/,/Optional Packages:/p' | sed -e '/^ [A-Z]/d' -e 's/^[[:space:]]*[-=+[:space:]]//'))
INCLUDE_PKGS+=($(rpm --qf '%{name}\n' -qf /etc/yum.repos.d/* 2>&1 | grep -v "not owned" | sort -u || true))
INCLUDE_PKGS+=(
    authconfig
    chrony
    cloud-init
    cloud-utils-growpart
    dracut-config-generic
    gdisk
    grub2
    grub2-tools
    iptables-services
    iptables-utils
    kernel
    kexec-tools
    lvm2
    ntp
    ntpdate
    openssh-clients
    openssh-server
    rdma-core
    rootfiles
    rsync
    selinux-policy-targeted
    sudo
    tar
    vim-common
    wget
    yum-utils
)
if [[ -n "$FIPSRPM" ]];
then
    INCLUDE_PKGS+=("$FIPSRPM")
fi

# Setup the "exclude" package list
EXCLUDE_PKGS=(
    -abrt
    -abrt-addon-ccpp
    -abrt-addon-kerneloops
    -abrt-addon-python
    -abrt-cli
    -abrt-libs
    -aic94xx-firmware
    -alsa-firmware
    -alsa-lib
    -alsa-tools-firmware
    -bfa-firmware
    -biosdevname
    -gcc-gfortran
    -iprutils
    -ivtv-firmware
    -iwl1000-firmware
    -iwl100-firmware
    -iwl105-firmware
    -iwl135-firmware
    -iwl2000-firmware
    -iwl2030-firmware
    -iwl3160-firmware
    -iwl3945-firmware
    -iwl4965-firmware
    -iwl5000-firmware
    -iwl5150-firmware
    -iwl6000-firmware
    -iwl6000g2a-firmware
    -iwl6000g2b-firmware
    -iwl6050-firmware
    -iwl7260-firmware
    -libertas-sd8686-firmware
    -libertas-sd8787-firmware
    -libertas-usb8388-firmware
    -libvirt-client
    -libvirt-devel
    -libvirt-java
    -libvirt-java-devel
    -nc
    -NetworkManager
    -plymouth
    -ql2100-firmware
    -ql2200-firmware
    -ql23xx-firmware
    -rdma
    -sendmail
)

# Strip excluded pkgs from the include list
for PKG in "${EXCLUDE_PKGS[@]}"
do
    mapfile -t INCLUDE_PKGS < <(printf '%s\n' "${INCLUDE_PKGS[@]}" | grep -xv "^${PKG/-/}$")
done

# Install main RPM-groups
$YUMDO -- "${INCLUDE_PKGS[@]}" "${EXCLUDE_PKGS[@]}"

# Validate all included packages were installed
rpm --root "${CHROOT}" -q "${INCLUDE_PKGS[@]}"

# Install additionally-requested RPMs
if [[ ! -z ${EXTRARPMS+xxx} ]]
then
   printf "##########\n## Installing requested RPMs/groups\n##########\n"
   for RPM in "${EXTRARPMS[@]}"
   do
      { STDERR=$(${YUMDO} "$RPM" 2>&1 1>&$out); } {out}>&1 || echo "$STDERR" | grep "Error: Nothing to do"
   done

else
   echo "No 'extra' RPMs requested"
fi
