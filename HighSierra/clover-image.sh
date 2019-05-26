#!/bin/bash

# https://github.com/kraxel/imagefish

######################################################################
# defaults

iso=""
img=""
cfg=""

######################################################################
# create work dir

function msg() {
	local txt="$1"
	local bold="\x1b[1m"
	local normal="\x1b[0m"
	echo -e "${bold}### ${txt}${normal}"
}

function do_cleanup() {
	msg "cleaning up ..."
	if test "$GUESTFISH_PID" != ""; then
		guestfish --remote -- exit >/dev/null 2>&1 || true
	fi
	sudo rm -rf "$WORK"
}

WORK="${TMPDIR-/var/tmp}/${0##*/}-$$"
mkdir "$WORK" || exit 1
trap 'do_cleanup' EXIT

BASE="$(dirname $0)"

######################################################################
# parse args

function print_help() {
cat <<EOF
usage: $0 [ options ]
options:
    --iso <iso-image>
    --img <disk-image>
    --cfg <clover-config>
EOF
}

while test "$1" != ""; do
	case "$1" in
	--iso)
		iso="$2"
		shift; shift
		;;
	--img)
		img="$2"
		shift; shift
		;;
	--cfg)
		cfg="$2"
		shift; shift
		;;
	esac
done

######################################################################
# guestfish script helpers

function fish() {
	echo "#" "$@"
	guestfish --remote -- "$@"		|| exit 1
}

function fish_init() {
	local format

	case "$img" in
	*.raw)	format="raw" ;;
	*)	format="qcow2";;
	esac

	msg "creating and adding disk image"
	fish disk-create $img $format 256M
	fish add $img
	fish run
}

function fish_fini() {
	fish umount-all
}

######################################################################
# sanity checks

if test ! -f "$iso"; then
	echo "ERROR: iso not found: $iso"
	exit 1
fi
if test ! -f "$cfg"; then
	echo "ERROR: cfg not found: $cfg"
	exit 1
fi
if test -f "$img"; then
	if test "$allow_override" = "yes"; then
		rm -f "$img"
	else
		echo "ERROR: image exists: $img"
		exit 1
	fi
fi

######################################################################
# go!

msg "copy files from iso"
guestfish -a "$iso" -m "/dev/sda:/:norock" <<EOF || exit 1
copy-out /EFI $WORK
EOF

#msg "[debug] list drivers in EFI/CLOVER"
#(cd $WORK/EFI/CLOVER; find driver* -print)

export LIBGUESTFS_BACKEND=direct
eval $(guestfish --listen)
if test "$GUESTFISH_PID" = ""; then
	echo "ERROR: starting guestfish failed"
	exit 1
fi

fish_init

msg "partition disk image"
fish part-init /dev/sda gpt
fish part-add /dev/sda p 2048 200000
fish part-add /dev/sda p 202048 -2048
fish part-set-gpt-type /dev/sda 1 C12A7328-F81F-11D2-BA4B-00A0C93EC93B
fish part-set-bootable /dev/sda 1 true
fish mkfs vfat /dev/sda1 label:EFI
fish mkfs vfat /dev/sda2 label:clover
fish mount /dev/sda2 /
fish mkdir /ESP
fish mount /dev/sda1 /ESP

msg "copy files to disk image"
cp -v "$cfg" $WORK/config.plist
fish mkdir                                     /ESP/EFI
fish mkdir                                     /ESP/EFI/CLOVER
fish copy-in $WORK/EFI/BOOT                    /ESP/EFI
fish copy-in $WORK/EFI/CLOVER/CLOVERX64.efi    /ESP/EFI/CLOVER

# With the inclusion of PartitionDxe-64.efi and ApfsDriverLoader-64.efi in your
# drivers64UEFI folder there will no longer be a need to add apfs.efi manually.
# - Borrowed from https://hackintosher.com/ forums.
fish copy-in $WORK/EFI/CLOVER/drivers64UEFI    /ESP/EFI/CLOVER
fish copy-in $WORK/EFI/CLOVER/drivers-Off/drivers64UEFI/PartitionDxe-64.efi \
					       /ESP/EFI/CLOVER/drivers64UEFI
fish copy-in $WORK/EFI/CLOVER/drivers-Off/drivers64UEFI/ApfsDriverLoader-64.efi \
					       /ESP/EFI/CLOVER/drivers64UEFI

fish copy-in $WORK/EFI/CLOVER/tools            /ESP/EFI/CLOVER
fish copy-in $WORK/config.plist                /ESP/EFI/CLOVER
# AudioDxe introduced since Clover-v2.4k-4844-X64.iso hangs on boot
fish rm /ESP/EFI/CLOVER/drivers64UEFI/AudioDxe-64.efi

nodef="$WORK/EFI/CLOVER/drivers-Off/drivers64UEFI"
if test -f $nodef/OsxAptioFix3Drv-64.efi; then
	echo "# -*- OsxAptioFix v3 -*-"
	fish copy-in $nodef/OsxAptioFix3Drv-64.efi /ESP/EFI/CLOVER/drivers64UEFI
else
	echo "# -*- OsxAptioFix v2 -*-"
	fish copy-in $nodef/OsxAptioFix2Drv-64.efi /ESP/EFI/CLOVER/drivers64UEFI
fi
fish ls /ESP/EFI/CLOVER/drivers64UEFI
fish_fini
