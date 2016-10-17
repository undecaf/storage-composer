#!/bin/bash

# StorageComposer
# ===============
#
# A script for creating and managing hard disk storage under Ubuntu, from
# simple situations (single partition) to complex ones (multiple drives/partitions, 
# different file systems, encryption, RAID and SSD caching in almost any combination).
#
# This script can also install a minimal Ubuntu and make the storage bootable.
#
# Copyright 2016 Ferdinand Kasper, fkasper@modus-operandi.at
#
# This file is part of "StorageComposer".
#
# StorageComposer is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# StorageComposer is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with StorageComposer.  If not, see <http://www.gnu.org/licenses/>.
#

# ------------------------------ Configuration -----------------------------

# This script without file extension
HERE="$(dirname $(readlink -e $0))"
SCRIPT_NAME=$(basename -s .sh ${0})

# Saved configuration
DEFAULT_CONFIG_FILE=$HOME/.${SCRIPT_NAME}.conf
CONFIG_FILE=$DEFAULT_CONFIG_FILE

# Passphrase expiration time in keyring (in s)
PW_EXPIRATION=300

# Absolute path to initramfs keyscript in target system
KEY_SCRIPT=/usr/local/sbin/keyscript

# RAID udev rule for adjusting drive/driver error timeouts
RAID_HELPER_FILE=/usr/local/sbin/mdraid-helper
RAID_RULE_FILE=/etc/udev/rules.d/90-mdraid.rules

# Replacement for standard udev bcache rule
BCACHE_HELPER_FILE=/usr/local/sbin/bcache-helper
BCACHE_HINT_FILE=$(dirname $BCACHE_HELPER_FILE)/bcache-hints

# File system types to choose from
AVAILABLE_FS_TYPES='ext2 ext3 ext4 btrfs xfs swap'

# RAID levels available for 0...4 components
AVAILABLE_RAID_LEVELS=('' '' '0 1' '0 1 4 5' '0 1 4 5 6 10')

# SSD erase block sizes for make-bcache
AVAILABLE_ERASE_BLOCK_SIZES='64k 128k 256k 512k 1M 2M 4M 8M 16M 32M 64M'

# Friendly names of authorization methods (0 is unused)
AUTH_METHODS=('' 'passphrase' 'key file' 'encrypted key file')

# Default mount options, applied to host mounts and target system
declare -A DEFAULT_MOUNT_OPTIONS=([ext2]=relatime,errors=remount-ro [ext3]=relatime [ext4]=relatime [btrfs]=compress=lzo,relatime [xfs]=relatime)

# Maximum waiting time until a device, file etc. becomes available (in s)
MAX_WAIT=10


# --------------------------------------------------------------------------

# Verifies that this script is run as root and in sudo.
#
verify_sudo() {
  if [ "$USER" != 'root' -o "$SUDO_USER" = 'root' -o -z "$SUDO_USER" ]; then
    echo 'This script can only be run as root and in sudo.' 1>&2
    exit 1
  fi
}


# --------------------------------------------------------------------------

# Installs the specified package(s) unless already installed. '-t' as first
# argument installs the package(s) also in the target system.
#
# Arguments:
#   $1           -t or first package name
#   $2, $3, ...  additional package name(s) (optional)
#
TARGET_PKGS=

install_pkg() {
  local TARGET_OPT
  if [ "$1" = '-t' ]; then
    TARGET_OPT=1
    shift
  fi

  for P; do
    dpkg -L "$P" > /dev/null 2>&1 || apt-get --no-install-recommends -q -y install "$P"
  done

  [ -n "$TARGET_OPT" ] && TARGET_PKGS="$TARGET_PKGS $@" || true
}


# --------------------------------------------------------------------------

# Displays a message on stdout; pauses this script if in DEBUG_MODE.
#
# Arguments:
#   $1           message to display
#   $DEBUG_MODE  enables breakpoints if non-empty
#
breakpoint() {
  echo $'\n'"$1"
  if [ "$DEBUG_MODE" ]; then
    local REPLY
    read -erp $'\n[Enter] to continue or Ctrl-C to abort: '
  fi
}


# --------------------------------------------------------------------------

# Prints a message to sterr and terminates this script with the specified 
# exit code.
#
# Arguments:
#   $1  error message
#   $2  exit code (optional, defaults to 2)
#
die() {
  local EXIT_CODE=2
  [ "$2" ] && EXIT_CODE="$2"
  echo $'\n'"****** FATAL: $1 ******" 1>&2
  exit $EXIT_CODE
}


# --------------------------------------------------------------------------

# Saves command groups that will be run on exit. Commands groups will be
# run in reverse order; commands within a command group are run in-order. 
#
# Arguments:
#   $1           description of command group, printed at stdout before
#                command group runs
#   $2, $3, ...  command group to be run on exit
#
on_exit() {
  if [ ! -f "$EXIT_SCRIPT" ]; then
    # Prepare the cleanup script
    EXIT_SCRIPT=$(mktemp)
    trap "{ set +e +x; echo \$'\nStarting cleanup'; tac $EXIT_SCRIPT | . /dev/stdin; rm $EXIT_SCRIPT; exit; }" EXIT
    echo "echo 'End of cleanup'" >> $EXIT_SCRIPT
  fi

  local DESC=$1
  shift 1
  local CMDS=("$@")
  local I

  for ((I=${#CMDS[@]}-1; I>=0; I--)); do
    echo "${CMDS[$I]}" >> $EXIT_SCRIPT
  done

  echo "echo '$DESC'" >> $EXIT_SCRIPT
}


# --------------------------------------------------------------------------

# Prompts for text input and verifies that the text is not empty and  
# is contained in a list of valid values (optional). Spaces are removed 
# from the text. Prints the text to stdout. Error messages go to stderr.
#
# Arguments:
#   $1           prompt
#   $2           default value (optional)
#   $3           space-separated list of valid value regexps (optional)
#   $BATCH_MODE  non-empty if running not interactively
#
read_text() {
  [ "$BATCH_MODE" ] && die "Cannot respond to '$1' in batch mode"

  local REPLY
  local DONE=
  local VALUES_RE='[^[:space:]]+'
  [ "$3" ] && VALUES_RE="^(${3// /|})$"

  until [ "$DONE" ]; do
    read -erp "$1" -i "$2"
    REPLY=${REPLY// /}
    if [[ "$REPLY" =~ $VALUES_RE ]]; then
      DONE=1
    elif [ -z "$3" ]; then
      echo '*** Input must not be blank ***' 1>&2
    else
      echo "*** Input must be one of: ${3// /, } ***" 1>&2
    fi
  done

  echo -n "$REPLY"
}


# --------------------------------------------------------------------------

# Prompts for an integer value and prints that value to stdout. Limits may
# be specified. Error messages go to stderr.
#
# Arguments:
#   $1           prompt
#   $2           default value (optional)
#   $3           lower limit (optional)
#   $4           upper limit (optional)
#   $BATCH_MODE  non-empty if running not interactively
#
read_int() {
  [ "$BATCH_MODE" ] && die "Cannot respond to '$1' in batch mode"

  local REPLY
  local DONE=
  local INT_RE='^[+-]?[0-9]+$'
  [ ! "$3" ] || [[ "$3" =~ $INT_RE ]] || die "Not an integer: $3"
  [ ! "$4" ] || [[ "$4" =~ $INT_RE ]] || die "Not an integer: $4"

  until [ "$DONE" ]; do
    read -erp "$1" -i "$2"
    if ! [[ "$REPLY" =~ $INT_RE ]]; then
      echo "*** Not an integer number: $REPLY ***" 1>&2
    elif [ -n "$3" ] && [ "$REPLY" -lt $3 ]; then
      echo "*** Number must be >= $3 ***" 1>&2
    elif [ -n "$4" ] && [ "$REPLY" -gt $4 ]; then
      echo "*** Number must be <= $4 ***" 1>&2
    else
      DONE=1
    fi
  done

  echo -n "$REPLY"
}


# --------------------------------------------------------------------------

# Ensures that the keyring contains a passphrase for the current
# configuration and prints the passphrase ID to stdout. Error messages go to
# stderr.
# If a prompt was specified or if no passphrase is available then the user
# is prompted for one (including verification). 
# Otherwise, the user may either enter a new passphrase or keep the previous
# one.
#
# Arguments:
#   $1              prompt for new passphrase (optional)
#   $CONFIG_FILE    name of configuration file
#   $PW_EXPIRATION  passphrase expiration time (in s, from last call of this
#                   function)
#   $BATCH_MODE     non-empty if running not interactively
# Calls:
#   install_pkg
#
read_passphrase() {
  [ "$BATCH_MODE" ] && die "Cannot enter a passphrase in batch mode"

  install_pkg keyutils

  local REPLY
  local PW_DESC="pw:$CONFIG_FILE"

  # Repeat only if the passphrase expires while in this loop
  while true; do
    local ID

    if [ "$1" ]; then
        read -ersp "$1"
    else
      ID=$(keyctl search @u user "$PW_DESC" 2>/dev/null)
      if [ "$ID" ]; then
        read -ersp '  Enter passphrase (empty for previous one): '
        [ "${REPLY// /}" ] && ID=
      else
        read -ersp '  Enter passphrase: '
      fi
    fi

    echo '' 1>&2

    if [ ! "$ID" ]; then
      # New passphrase, or no passphrase in keyring
      local PW

      while [ "$1" ]; do
        PW="$REPLY"
        read -ersp '  Repeat passphrase: '
        echo '' 1>&2
        [ "$REPLY" = "$PW" ] && break
        echo '  *** Passphrases do not match, please try again ***' 1>&2
        read -ersp '  Enter passphrase: '
        echo '' 1>&2
      done

      # Save passphrase to keyring
      ID=$(echo -n "$REPLY" | keyctl padd user "$PW_DESC" @u)
    fi

    # Repeat if passphrase expired while in this loop
    keyctl timeout $ID $PW_EXPIRATION 2>/dev/null && break
    echo '  *** Previous passphrase expired, enter a new one ***' 1>&2
  done

  echo $ID
}


# --------------------------------------------------------------------------

# Prompts for a file and optionally verifies that the file meets a test.
# Prints the canonical file path to stdout if the file exists. Otherwise,
# prints what was entered. Error messages go to stderr.
#
# Arguments:
#   $1           prompt
#   $2           default value (optional)
#   $3           a file test of the 'test' command: -r, -d, -e, ... (optional)
#   $4           allows empty input if present and non-empty (optional)
#   $BATCH_MODE  non-empty if running not interactively
#
read_filepath() {
  [ "$BATCH_MODE" ] && die "Cannot respond to '$1' in batch mode"

  local DEFAULT=$2
  local REPLY
  case "$3" in
    -b|-c|-d|-e|-f|-g|-G|-h|-k|-L|-O|-p|-r|-s|-S|-u|-w|-x|'')
      TEST="$3"
      ;;
    *)
      die "Invalid file test: $3"
      ;;
  esac

  until [ "$REPLY" ]; do
    read -erp "$1" -i "$DEFAULT"

    [ -n "$4" -a -z "${REPLY// /}" ] && echo '' && return

    # Remove trailing space from filename that might have been added 
    # by auto-completion
    REPLY=${REPLY% }
    
    if [ ! $TEST "$REPLY" ]; then
      echo "*** Invalid path or unsuitable file: $REPLY ***" 1>&2
      DEFAULT=$REPLY
      REPLY=
    fi
  done

  readlink -e "$REPLY" 2>/dev/null || echo "$REPLY"
}


# --------------------------------------------------------------------------

# Prompts for one or several absolute directory paths and verifies that 
# they exist. Prints the directory paths to stdout. Error messages go to 
# stderr.
#
# Arguments:
#   $1           prompt
#   $2           default value (optional)
#   $3           allows entering multiple paths if present and non-empty (optional)
#   $BATCH_MODE  non-empty if running not interactively
#
read_dirpaths() {
  [ "$BATCH_MODE" ] && die "Cannot respond to '$1' in batch mode"

  local DEFAULT=$2
  local REPLY=

  until [ "$REPLY" ]; do
    read -erp "$1" -i "$DEFAULT"

    I=0
    for P in $REPLY; do
      I=$(($I+1))

      if [ $I -gt 1 -a -z "$3" ]; then
        echo "*** Only one path may be entered ***" 1>&2
        DEFAULT="$REPLY"
        REPLY=
        continue 2
      elif [[ "$P" != /* ]]; then
        echo "*** Not an absolute path: $P ***" 1>&2
        DEFAULT="$REPLY"
        REPLY=
          continue 2
      elif [ ! -d "$P" ]; then
        echo "*** Not a directory: $P ***" 1>&2
        DEFAULT="$REPLY"
        REPLY=
        continue 2
      fi
    done
  done

  echo -n "$REPLY"
}


# --------------------------------------------------------------------------

# Prompts for one or several block devices and prints the selection as
# space-separated device paths to stdout. For brevity, the leading
# '/dev/' path components may be omitted.They will be added to the output
# if necessary.  Only unmounted devices having no holders are allowed.
# Error messages go to stderr.
#
# Arguments:
#   $1           prompt
#   $2           default value (optional)
#   $3           allows for multiple devices if present and non-empty (optional)
#   $4           allows empty input if present and non-empty (optional)
#   $BATCH_MODE  non-empty if running not interactively
#   $BUILD_GOAL  non-empty if building a new storage
#   $MOUNT_GOAL  non-empty if mounting a storage
# Calls:
#   available_devs, contains_word
#
read_devs() {
  [ "$BATCH_MODE" ] && die "Cannot reply to '$1' in batch mode"

  local AVAILABLE_DEVS="$(available_devs $BUILD_GOAL$MOUNT_GOAL)"
  local SELECTION=
  local DEFAULT=$2
  local REPLY
  
  # Repeat until input is valid
  until [ "$SELECTION" ]; do
    read -erp "$1" -i "$DEFAULT"

    SELECTION=
    [ -n "$4" -a -z "${REPLY// /}" ] && break

    for P in $REPLY; do
	  # Add leading /dev/ if necessary
      if [ "${P#/dev/}" = "$P" ]; then
        P="/dev/$P"
      fi
      
      if [ -n "$SELECTION" -a -z "$3" ]; then
        echo "*** Only one block device may be entered ***" 1>&2
        DEFAULT="$REPLY"
        SELECTION=
        continue 2
      elif ! contains_word "$AVAILABLE_DEVS" "$P"; then
        echo "*** Device is mounted or has a holder or is unknown: $P ***" 1>&2
        DEFAULT="$REPLY"
        SELECTION=
        continue 2
      else
        SELECTION="$SELECTION $P"
      fi
    done
  done

  echo -n "${SELECTION/ /}"
}


# --------------------------------------------------------------------------

# Prompts the user for confirmation and returns status 0 if accepted or a
# non-zero status if rejected. Aborts if no default value is provided in
# batch mode.
#
# Arguments:
#   $1           prompt
#   $2           default value (optional)
#   $BATCH_MODE  non-empty if running not interactively
#
confirmed() {
  local REPLY
  
  if [ "$BATCH_MODE" ]; then
    [ "$2" ]  || die "No default response for '$1'"
    REPLY="$2"
  else
    read -erp "$1 (y/n)? " -i "$2"
  fi
  
  test "$REPLY" == Y -o "$REPLY" == y
}


# --------------------------------------------------------------------------

# Returns status 0 iff a white-space-delimited list contains a certain word.
#
# Arguments:
#   $1  space-delimited list of words
#   $2  word to search for
#
contains_word() {
  [[ "$1" =~ (^|[[:space:]]+)"$2"($|[[:space:]]+) ]]
}


# --------------------------------------------------------------------------

# Sorts the specified words, removes duplicates and prints the result to
# stdout.
#
# Arguments:
#   $1, $2, $3, ... words
#
sorted_unique() {
  echo $* | xargs -n1 | sort -u | xargs
}


# --------------------------------------------------------------------------

# Finds the disks of the specified partitions, removes duplicate disks and
# prints the sorted result to stdout.
#
# Arguments:
#   $1, $2, $3, ... partitions (/dev/*[1-9])
#
sorted_unique_disks() {
  echo $* | xargs -n1 | sed -e 's/[1-9]$//' | sort -u | xargs
}


# --------------------------------------------------------------------------

# Sorts the specified words and prints only the duplicates to stdout.
#
# Arguments:
#   $1, $2, $3, ... words
#
sorted_duplicates() {
  echo $* | xargs -n1 | sort | uniq -d | xargs
}


# --------------------------------------------------------------------------

# Builds a file path from the argument and ensures that no such file exists
# yet. The resulting path is printed to stdout.
#
# Arguments:
#   $1  desired file path
#
new_path() {
  local N

  while [ -e "${1}${N}" ]; do
    N=$((N+1))
  done

  echo -n "${1}${N}"
}


# --------------------------------------------------------------------------

# Prints a whitespace-delimited list of available block devices to stdout.
# The list can be restricted to those devices that are neither mounted nor
# have any holder.
#
# Arguments:
#   $1  if non-empty: print only devices that are neither mounted nor have any
#       holder
# Calls:
#   dev_dirs, contains_word
#
available_devs() {
  local AVAILABLE_DEVS=$(blkid -po device /dev/sd?[1-9]*)
  
  if [ "$1" ]; then
    local D

    for D in $AVAILABLE_DEVS; do
      dev_dirs $D   
      [ -z "$(/bin/ls -A $HOLDERS_DIR)" ] \
        && ! contains_word "$(cat /proc/mounts)" "$D" \
        && continue  
      AVAILABLE_DEVS=${AVAILABLE_DEVS/$D/}
    done
  fi
  
  echo -n "$AVAILABLE_DEVS"
}


# --------------------------------------------------------------------------

# Waits until the specified device is available and then saves the device
# directories DEV_DIR, BCACHE_DIR and HOLDERS_DIR.
#
# Arguments:
#   $1  device path (/dev/*)
# Results:
#   DEV_DIR      device directory below /sys/block
#   BCACHE_DIR   $DEV_DIR/bcache
#   HOLDERS_DIR  $DEV_DIR/holder
# Calls:
#   wait_file
#
dev_dirs() {
  wait_file $1
  DEV_DIR=$(find -L /sys/block -maxdepth 2 -type d -name $(basename $(readlink -e $1)))
  BCACHE_DIR=$DEV_DIR/bcache
  HOLDERS_DIR=$DEV_DIR/holders
}


# --------------------------------------------------------------------------

# Prints the block device(s) that belong to the specified UUID to stdout.
# For RAID UUIDs, this can be several components.
#
# Arguments:
#   $1  UUID
#
uuid_to_devs() {
  if [ "$1" ]; then
    local DEVS=$(blkid | awk -F ':' -e /$1/' { printf " %s", $1; }')
    echo -n "${DEVS/ /}"
  fi
}


# --------------------------------------------------------------------------

# Prints the UUID that corresponds to the specified block device to stdout.
#
# Arguments:
#   $1  device
#
dev_to_uuid() {
  if [ "$1" ]; then
    local UUID=$(blkid -p -o value -s UUID "$1" 2>/dev/null)
    # Must not read superblocks to get UUID of /dev/mapper/*
    [ "$UUID" ] || UUID=$(blkid -o value -s UUID "$1" 2>/dev/null)
    echo "$UUID"
  fi
}


# --------------------------------------------------------------------------

# In a list of block devices, tries to replace each device by the matching
# /dev/disk/by-uuid device. If there is no UUID or if the device is one of
# /dev/mapper/* then it is not replaced.
# Prints the resulting list to stdout.
#
# Arguments:
#   $1, $2, $3, ...  device paths (/dev/*, ...)
# Calls:
#   dev_to_uuid
#
devs_to_disks_by_uuid() {
  local REPLACED_DEVS=
  local DEV

  for DEV in $@; do
    if [[ $DEV != /dev/mapper/* ]]; then
      local UUID=$(dev_to_uuid $DEV)
      [ "$UUID" ] && DEV=/dev/disk/by-uuid/$UUID
    fi

    REPLACED_DEVS="$REPLACED_DEVS $DEV"
  done

  echo ${REPLACED_DEVS/ /}
}


# --------------------------------------------------------------------------

# Returns status 0 iff the specified block device is an SSD.
#
# Arguments:
#   $1  block device
#
is_ssd() {
  [ "$(lsblk -dnro RM,ROTA $1 2>/dev/null)" = '0 0' ]
}


# --------------------------------------------------------------------------

# Prints the mount point-relative path of the specified file path to stdout.
# The file does not need to exist, but its parent directory must exist.
# Returns 0 if the parent directory exists, otherwise returns a non-zero
# value.
#
# Arguments:
#   $1  file path
#
mount_point_relative() {
  local DIR_NAME=$(readlink -e $(dirname $1)) || return
  local MP=$(stat --printf '%m' $DIR_NAME) || return
  echo -n "${DIR_NAME#$MP}/$(basename $1)"
}


# --------------------------------------------------------------------------

# Waits until a file, directory or device exists in the file system and
# (optionally) the output from this device matches some pattern. Fails and
# returns exit code 1 if $MAX_WAIT seconds have passed without success.
#
# Arguments:
#   $1         file, directory or device name
#   $2         expected output (optional)
#   $MAX_WAIT  maximum waiting time (in seconds)
#
wait_file() {
  local MSG="Waiting for $1 $2 "
  local ECHO='true'
  local I=$MAX_WAIT

  while true; do
    [ -z "$2" ] && [ -e "$1" ] && break
    [ -f "$1" ] && [ "$(cat $1)" = "$2" ] && break

    I=$(($I-1))
    if [ $I -le 0 ]; then
      echo " gave up waiting"
      return 1
    fi

    echo -n "$MSG"
    sleep 1
    MSG='.'
    ECHO=echo
  done

  $ECHO
}


# --------------------------------------------------------------------------

# Adds a device to FSTAB, identifying it by UUID unless it is a mapped 
# device (/dev/mapper/*).
#
# Arguments:
#   $1  device to add
#   $2  mount point
#   $3  file system type
#   $4  options (optional, defaults to 'defaults')
#   $5  pass (0=no fsck, 1=fsck first, 2=fsck afterwards)
# Calls:
#   dev_to_uuid
#

# /etc/fstab is being built here
FSTAB='# <device>	<mount point>	<file system type>	<options>	<dump>	<pass>'

add_fstab() {
  local UUID
  [[ $1 != /dev/mapper/* ]] && UUID=$(dev_to_uuid $1)

  if [ -n "$UUID" ]; then
    FSTAB="${FSTAB}\n# Device was $1 at installation:"
    local DEV="UUID=$UUID"
  else
    local DEV=$1
  fi

  local OPTIONS=${4:-defaults}

  FSTAB="${FSTAB}\n$DEV	$2	$3	$OPTIONS	0	$5"
}


# --------------------------------------------------------------------------

# Formats a LUKS device and adds a corresponding CRYPTTAB entry. AUTH_METHOD
# and MP_REL_KEY_FILE are put into the <key file> argument, using ':' as 
# separator.
#
# Arguments:
#   $1               device to format
#   $2               mapped device name
#   $AUTH_METHOD     LUKS authorization method
#   $KEY_SCRIPT      absolute path to initramfs keyscript in target system
#   $MP_REL_KEY_FILE mount point-relative path of <key file> in crypttab entry
#   $KEY_ID          keyring ID of passphrase
# Calls:
#   devs_to_disks_by_uuid, is_ssd
#

# /etc/crypttab is being built here
CRYPTTAB='# <target name>		<source device>		<key file>		<options>'

format_luks() {
  # Format LUKS device
  keyctl pipe $KEY_ID | cryptsetup --batch-mode --hash sha512 --key-size 512 --key-file - luksFormat $1

  # Change LUKS authorization method from 1 to 0 for the first occurrence
  # This forces passphrase entry in $KEY_SCRIPT and prevents saving a wrong
  # password to the keyring
  local AUTH_METHOD_=$AUTH_METHOD
  [ "$AUTH_METHOD" = 1 ] && ! contains_word "$CRYPTTAB" "0:$MP_REL_KEY_FILE" && AUTH_METHOD_=0

  # Add a 'discard' option for SSDs
  local DISCARD
  is_ssd $1 && DISCARD=,discard

  # Add CRYPTTAB entry
  CRYPTTAB="$CRYPTTAB\n$2 $(devs_to_disks_by_uuid $1) $AUTH_METHOD_:$MP_REL_KEY_FILE luks,initramfs,keyscript=$KEY_SCRIPT,x-systemd.device-timeout=10$DISCARD"
}


# --------------------------------------------------------------------------

# Creates an initramfs hook for update-initramfs. The target file system
# must be mounted at $TARGET when this function is called.
#
# Arguments:
#   $1           hook name (must be unique)
#   $2, $3, ...  pairs of switches and names. File paths must be absolute 
#                within the target file system, i.e. relative to $TARGET.
#                -c <file>: copies <file> to the same path in initramfs
#                -x <file>: copies (executable) <file> to /bin in initramfs
#                -l <module>: forces kernel <module> to be loaded on boot
#   $TARGET      mount point of target file system
#
initramfs_hook() {
  mkdir -p "$TARGET/etc/initramfs-tools/hooks"
  local HOOK="$TARGET/etc/initramfs-tools/hooks/$1"
  shift

  cat > "$HOOK" <<- EOF
	#!/bin/sh
	[ "\$1" = prereqs ] && echo '' && exit 0
	. /usr/share/initramfs-tools/hook-functions
EOF

  while [ "$2" ]; do
    case "$1" in
      -c)
        echo 'mkdir -p "${DESTDIR}'"$(dirname $2)"'"' >> "$HOOK"
        echo 'cp "'"$2"'" "${DESTDIR}'"$2"'"' >> "$HOOK"
        ;;
      -x)
        echo "copy_exec '$2' /bin" >> "$HOOK"
        ;;
      -l)
        echo "force_load $2" >> "$HOOK"
        ;;
    esac
    shift 2
  done

  echo 'exit 0' >> "$HOOK"
  chmod 755 "$HOOK"
}


# --------------------------------------------------------------------------

# Binds special block devices of the host on the target system. These
# devices are required for chroot-ing into the target system.
#
# Arguments:
#   $TARGET      mount point of target file system
#
mount_devs() {
  echo "Mounting devices for chroot-ing into $TARGET"
  for D in /dev /dev/pts /proc /run/resolvconf /run/lock /sys; do
    mkdir -p ${TARGET}${D}
    mount --bind $D ${TARGET}${D}
  done

  sleep 3   # wait until everything has settled
}


# --------------------------------------------------------------------------

# Prints usage information and an optional error message to stdout or stderr
# and exits with error code 0 or 1, respectively.
#
# Arguments:
#   $1  (optional) error message: if specified then it is printed, and all
#       output is sent to stderr;  otherwise output goes to stdout.
#
usage() {
  local SCRIPT=$(basename $0)
  local REDIR=
  local EXIT_CODE=0

  if [ -n "$1" ]; then
    cat >&2 <<- EOF

*** $1 ***
EOF
    REDIR=">&2"
    EXIT_CODE=1
  fi

  eval "cat $REDIR" <<- EOF

This script builds and/or (un-)mounts a storage system using RAID,
SSD caching and LUKS encryption in any combination. Encryption may
rely on a passphrase, a plaintext key file (may be located on an
encrypted partition) or an encrypted key file (two-factor
authentication).

Optionally, a minimal bootable $DISTRIB_DESCRIPTION can be installed
onto the target storage.

Usage: $SCRIPT -b|-m [-i] [-y] [-d] [<config-file>]
       $SCRIPT -u [-y] [<config-file>]
       $SCRIPT -h

  <config-file> describes the target storage and can be created and
  edited interactively prior to any other action. If no <config-file>
  is specified then $DEFAULT_CONFIG_FILE is used by default.

  Options:
    -h  Displays this text and exits.
    -b  (Re-)Builds the target storage and mounts it at the mount
        point specified in <config-file>. Host devices required for
        chrooting are also mounted. Existing data on the underlying
        block devices will be overwritten.
    -m  (Re-)Mounts a previously built target storage at the mount
        point specified in <config-file>. Host devices required for
        chrooting are also mounted. See -u for unmounting.
    -u  Unmounts everything from the target storage mount point and
        stops encryption, caching and RAIDs on the underlying devices.
    -i  Installs a minimal bootable $DISTRIB_DESCRIPTION onto the
        target storage, with the same architecture as the host system.
    -y  Batch mode: accepts default responses automatically, fails if
        any input beyond that is required. Use with caution.
    -d  Debug mode: pauses the script at various stages and makes the
        target system boot verbosely. Repeating this option increases
        the debugging level.

EOF
  exit $EXIT_CODE
}


# --------------------------------------------------------------------------

# Umounts the target file system and unlocks the specified block devices by
# stopping encryption, caching and RAIDs so that these devices are no longer
# busy.
#
# Arguments:
#   $1, $2, $3, ...  block devices (without leading /dev), in reverse order
#                    of configuration, cache devices at the end
#   $TARGET          mount point of target file system
# Calls:
#   dev_dirs, unlock_devs
#
cleanup() {
  set +e

  # Unmount everything from $TARGET
  for MP in $(cat /proc/mounts | grep "$TARGET"'[ /]' | cut -d ' ' -f 2 | sort -r); do
    echo "Unmounting $MP"
    umount -l $MP
    sleep 0.5
  done

  # Unlock devices recursively
  unlock_devs $@

  set -e
}

unlock_devs() {
  local D
  local DEV
  local MP
  local BC_DIR

  for D in $@; do
    dev_dirs /dev/$D
    BC_DIR=$BCACHE_DIR

    # Unlock any holders first
    [ "$(/bin/ls -A $HOLDERS_DIR)" ] && unlock_devs $(basename -a $HOLDERS_DIR/*)
    
    # Get device path
    case $D in
      dm-[1-9]*)
        DEV=/dev/mapper/$(cat /sys/block/$D/dm/name)
        ;;
      *)
        DEV=/dev/$D
        ;;
    esac

    # Turn off swapping
    swapoff $DEV 2>/dev/null || true

    # Unlock device
    case $D in
      md[1-9]*)
        echo -n "Stopping RAID $DEV .."
        sleep 0.5
        while true; do
          echo -n '.'
          # Sync will restart automatically soon
          echo idle >/sys/block/$D/md/sync_action
          # Will fail as long as the array is still being sync'ed
          mdadm --stop $DEV 1>&2 2>/dev/null && break
          sleep 3          
        done
        sleep 0.5
        echo ''
        ;;

      bcache[0-9]*)
        echo "Detaching cache $DEV"
        sleep 0.5
        echo 1 >$BC_DIR/detach
        echo 1 >$BC_DIR/stop
        sleep 0.5
        ;;

      dm-[1-9]*)
        echo "Closing mapped LUKS device $DEV"
        sleep 0.5
        cryptsetup luksClose $DEV
        sleep 0.5
        ;;

      sd*)
        if [ -e $BC_DIR/set/stop ]; then
          echo "Stopping caching device $DEV"
          sleep 0.5
          echo 1 >$BC_DIR/set/stop
          sleep 0.5
        fi
        ;;
    esac
  done
}


# ---------------------------- Script starts here --------------------------

# Identify the host's Ubuntu version
. /etc/lsb-release 2>/dev/null || die "Is this an Ubuntu host? (/etc/lsb-release not found)"

# Process command line arguments
OPTIONS=
BATCH_MODE=
DEBUG_MODE=

while getopts hbmiydu OPT; do
  case "$OPT" in
    h|b|m|i|u)
      OPTIONS="$OPTIONS $OPT"
      ;;
    y)
      BATCH_MODE=1
      ;;
    d)
      DEBUG_MODE=$((DEBUG_MODE+1))
      ;;
    \?)
      usage "Unknown option: $OPT"
      ;;
  esac
done

# Verify that the combination of options is valid
OPTIONS=$(sorted_unique "$OPTIONS")
BUILD_GOAL=
MOUNT_GOAL=
UNMOUNT_GOAL=
INSTALL_GOAL=
FRIENDLY_GOAL=

case "$OPTIONS" in
  h)
    usage
    ;;
  b)
    BUILD_GOAL=1
    FRIENDLY_GOAL='build'
    ;;
  'b i')
    BUILD_GOAL=1
    INSTALL_GOAL=1
    FRIENDLY_GOAL='build and install'
    ;;
  m)
    MOUNT_GOAL=1
    FRIENDLY_GOAL='mount'
    ;;
  'i m')
    MOUNT_GOAL=1
    INSTALL_GOAL=1
    FRIENDLY_GOAL='mount and install'
    ;;
  u)
    UNMOUNT_GOAL=1
    FRIENDLY_GOAL='unmount'
    ;;
  *)
    usage 'An option is missing, or the combination of options is invalid'
    ;;
esac

[ -n "$DEBUG_MODE" -a -n "$BATCH_MODE" ] && usage 'Cannot debug in batch mode'

# Remove parsed options
shift $(($OPTIND-1))

CONFIG_FILE="${1:-$DEFAULT_CONFIG_FILE}"

# Check whether running as root in sudo
verify_sudo

# Abort and clean up in case of an error
set -e
trap cleanup ERR

# Configuration variables
declare -a STORAGE_DEVS
declare -a STORAGE_DEVS_UUIDS=()
declare -a RAID_LEVELS
declare -a CACHED_BY
declare -a CACHED_BY_UUIDS=()
declare -a ENCRYPTED
declare -a FS_TYPES
declare -a MOUNT_POINTS
declare -a MOUNT_OPTIONS
declare -A ERASE_BLOCK_SIZES=()

TARGET=
AUTH_METHOD=
KEY_FILE=
KEY_FILE_SIZE=
PREFIX=
TARGET_HOSTNAME=$HOSTNAME

# Repeat configuration until confirmed by user
while true; do

  # ---------------------- Collect configuration info ------------------------

  if [ -z "$SKIP_CONFIG_FILE" -a -f $CONFIG_FILE ]; then
    # Read previous configuration
    . $CONFIG_FILE

    # Identify storage and caching devices by their UUIDs
    for (( I=0; I<${#STORAGE_DEVS_UUIDS[@]}; I++ )); do
      # RAID UUIDs will be expanded to a list of RAID components
      STORAGE_DEVS[$I]=$(uuid_to_devs ${STORAGE_DEVS_UUIDS[$I]})
    done

    for (( I=0; I<${#CACHED_BY_UUIDS[@]}; I++ )); do
      CACHED_BY[$I]=$(uuid_to_devs ${CACHED_BY_UUIDS[$I]})
    done

  else
    if [ -z "$BATCH_MODE" ]; then
      # Show overview of devices and unmounted partitions
      cat <<- EOF

Block devices
=============
  
EOF
      lsblk -o NAME,FSTYPE,SIZE,LABEL,MOUNTPOINT /dev/sd?  | grep -v /
      echo ''
    fi
    
    # Configure file systems, root file system first
    VOL_HINT='root '
    HINT=

    for (( NUM_FS=0; ; NUM_FS++ )); do
      # Storage devices for a file system
      DEVS=$(read_devs "Partition(s) for ${VOL_HINT}file system (two or more make a RAID$HINT): " "${STORAGE_DEVS[$NUM_FS]}" multiple $HINT)
      [ ! "$DEVS" ] && break

      STORAGE_DEVS[$NUM_FS]="$DEVS"
      HINT=', empty to continue'
      VOL_HINT='additional '

      # Request RAID level if more than one device specified
      DEVS=($DEVS)
      NUM_DEVS=${#DEVS[@]}
      if [ $NUM_DEVS -gt 1 ]; then
        [ $NUM_DEVS -gt 4 ] && NUM_DEVS=4
        RAID_LEVELS[$NUM_FS]=$(read_text '  RAID level: ' "${RAID_LEVELS[$NUM_FS]}" "${AVAILABLE_RAID_LEVELS[$NUM_DEVS]}")
      else
        RAID_LEVELS[$NUM_FS]=
      fi

      # Optional SSD cache device and SSD erase block size
      CACHE_DEV=$(read_devs '  SSD caching device (optional): ' "${CACHED_BY[$NUM_FS]}" '' optional)
      CACHED_BY[$NUM_FS]=$CACHE_DEV
      [ "$CACHE_DEV" ] && ERASE_BLOCK_SIZES[$CACHE_DEV]=$(read_text '    Erase block size: ' "${ERASE_BLOCK_SIZES[$CACHE_DEV]}" "$AVAILABLE_ERASE_BLOCK_SIZES")

      # Optional LUKS encryption
      [ "${ENCRYPTED[$NUM_FS]}" ] && DEFAULT=y || DEFAULT=n
      confirmed '  LUKS-encrypted' $DEFAULT && ENCRYPTED[$NUM_FS]=y || ENCRYPTED[$NUM_FS]=

      # File system type
      FS_TYPE=$(read_text '  File system: ' "${FS_TYPES[$NUM_FS]}" "$AVAILABLE_FS_TYPES")
      [ "$FS_TYPE" != "${FS_TYPES[$NUM_FS]}" ] && MOUNT_OPTIONS[$NUM_FS]=${DEFAULT_MOUNT_OPTIONS[$FS_TYPE]}
      FS_TYPES[$NUM_FS]=$FS_TYPE

      # Mount points
      DEFAULT="${MOUNT_POINTS[$NUM_FS]}"
      [ -z "$DEFAULT" -a $NUM_FS -eq 1 ] && DEFAULT=/
      case "${FS_TYPES[$NUM_FS]}" in
        btrfs)
          # Each mount point becomes a subvolume
          MOUNT_POINTS[$NUM_FS]=$(read_dirpaths '    Mount points (become top-level subvolumes with leading '@'): ' "$DEFAULT" multiple)
          ;;
        swap)
          # No mount point
          MOUNT_POINTS[$NUM_FS]=
          ;;
        *)
          # Single mount point
          MOUNT_POINTS[$NUM_FS]=$(read_dirpaths '    Mount point: ' "$DEFAULT")
          ;;
      esac

      # Mount options
      if [ "$FS_TYPE" != swap ]; then
        DEFAULT=${MOUNT_OPTIONS[$NUM_FS]}
        [ "$DEFAULT" ] || DEFAULT=${DEFAULT_MOUNT_OPTIONS[$FS_TYPE]}
        MOUNT_OPTIONS[$NUM_FS]=$(read_text '    Mount options (optional): ' "$DEFAULT" '^.*$')
      fi
    done

    # Remove unused configuration entries
    for (( I=${#STORAGE_DEVS[@]}-1; I>=$NUM_FS; I-- )); do
      unset STORAGE_DEVS[$I]
      unset STORAGE_DEVS_UUIDS[$I]
      unset RAID_LEVELS[$I]
      unset CACHED_BY[$I]
      unset CACHED_BY_UUIDS[$I]
      unset ENCRYPTED[$I]
      unset FS_TYPES[$I]
      unset MOUNT_POINTS[$I]
      unset MOUNT_OPTIONS[$I]
    done

    # Authorization is required if any file system is encrypted
    BLANK_RE='^ *$'
    if [[ "${ENCRYPTED[@]}" =~ $BLANK_RE ]]; then
      AUTH_METHOD=
      KEY_FILE=
      KEY_FILE_SIZE=

    else
      install_pkg gnupg keyutils

      PREV_AUTH_METHOD=$AUTH_METHOD
      AUTH_METHOD=$(read_text $'LUKS authorization method\n  1=passphrase\n  2=key file (may be on a LUKS partition)\n  3=encrypted key file: ' "$AUTH_METHOD" '1 2 3')

      # Enforce a new passphrase if the authorization method was changed or if building a new file system
      PROMPT=
      [ "$AUTH_METHOD" != "$PREV_AUTH_METHOD" -o -n "$BUILD_GOAL" ] && PROMPT='  Enter passphrase: '
      KEY_ID=
      PW_ID=

      case $AUTH_METHOD in
        1)
          # Save passphrase to keyring, use passphrase as key
          KEY_ID=$(read_passphrase "$PROMPT")
          KEY_FILE=
          KEY_FILE_SIZE=
          MP_REL_KEY_FILE=
          ;;

        2)
          # Select key file, create it if $BUILD_GOAL and not found
          while true; do
            KEY_FILE=$(read_filepath '  Key file (should be on a mounted removable device): ' "$KEY_FILE")

            if ! MP_REL_KEY_FILE=$(mount_point_relative "$KEY_FILE"); then
              # Directory does not exist
              echo "*** Directory does not exist: $(dirname $KEY_FILE) ***" 1>&2
              continue

            elif [ -r "$KEY_FILE" ]; then
              # Key file exists
              break

            elif [ -e "$KEY_FILE" -o -z "$BUILD_GOAL" ]; then
              # Something else exists, or we are not building the target file system
              echo "*** Not a readable file: $KEY_FILE ***" 1>&2
              continue

            else
              # Building the target file system, and key file does not exist -- create it
              confirmed "  $KEY_FILE does not exist, create it" || continue
              KEY_FILE_SIZE=$(read_int '    size (bytes): ' "$KEY_FILE_SIZE" 256 8192)
              gpg --gen-random 1 $KEY_FILE_SIZE > "$KEY_FILE"
              chmod 600 "$KEY_FILE"
              echo "  Key file $KEY_FILE created"
              break
            fi
          done
          ;;

        3)
          # Select encrypted key file, create it if $BUILD_GOAL and not found
          while true; do
            KEY_FILE=$(read_filepath '  Encrypted key file (should be on a mounted removable device): ' "$KEY_FILE")

            if ! MP_REL_KEY_FILE=$(mount_point_relative "$KEY_FILE"); then
              # Directory does not exist
              echo "*** Directory does not exist: $(dirname $KEY_FILE) ***" 1>&2
              continue

            elif [ -r "$KEY_FILE" ]; then
              # Key file exists, get and validate passphrase
              while true; do
                PW_ID=$(read_passphrase "$PROMPT")
                cat "$KEY_FILE" | gpg --quiet --yes --passphrase $(keyctl pipe $PW_ID) --output /dev/null && break 2
              done

            elif [ -e "$KEY_FILE" -o -z "$BUILD_GOAL" ]; then
              # Something else exists, or we are not building the target file system
              echo "*** Not a readable file: $KEY_FILE ***" 1>&2
              continue

            else
              # Building the target file system, and key file does not exist -- create it
              confirmed "  $KEY_FILE does not exist, create it" || continue
              KEY_FILE_SIZE=$(read_int '  size (256...8192): ' "$KEY_FILE_SIZE" 256 8192)

              # Get passphrase
              PW_ID=$(read_passphrase '  Enter passphrase: ')

              # Save encrypted random key in the key file
              gpg --quiet --gen-random 1 $KEY_FILE_SIZE | gpg --quiet --yes --symmetric --cipher-algo AES256 --s2k-digest-algo SHA256 --passphrase $(keyctl pipe $PW_ID) --output "$KEY_FILE"
              chmod 600 "$KEY_FILE"
              echo "  Encrypted key file $KEY_FILE created"
              break
            fi
          done
          ;;
      esac
    fi

    # Optional prefix to /dev/mapper names and volume labels
    PREFIX=$(read_text 'Prefix to mapper names and labels (recommended): ' "$PREFIX" '^[A-Za-z0-9_-]*$')
    
    # Target mount point
    while true; do
      TARGET=$(read_filepath 'Target mount point: ' "$TARGET")
      [ -d "$TARGET" ] && break
      confirmed "  $TARGET does not exist, create it" y && break
    done

    # Target system's hostname
    if [ "$INSTALL_GOAL" ]; then
      TARGET_HOSTNAME=$(read_text 'Hostname: ' "$TARGET_HOSTNAME" '^[[:alnum:]]+$')
    fi
  fi

  # Boot file system is the root file system or the file system having mount point /boot
  BOOT_DEV_INDEX=0
  for (( I=1; I<$NUM_FS; I++ )); do
    contains_word "${MOUNT_POINTS[$I]}" /boot && BOOT_DEV_INDEX=$I && break
  done

  # Determine boot devices
  BOOT_DEVS="$(sorted_unique_disks ${STORAGE_DEVS[$BOOT_DEV_INDEX]})"
  
  SKIP_CONFIG_FILE=1


  # -------------------------- Check configuration -------------------------

  ERROR=
  echo ''

  # Have all UUIDs been mapped to block devices? (cannot detect missing RAID components)
  for (( I=0; I<$NUM_FS; I++ )); do
    if [ -n "${STORAGE_DEVS_UUIDS[$I]}" -a -z "${STORAGE_DEVS[$I]}" ]; then
      echo "*** No device found with this UUID: ${STORAGE_DEVS_UUIDS[$I]} ***" 1>&2
      ERROR=1
    fi

    if [ -n "${CACHED_BY_UUIDS[$I]}" -a -z "${CACHED_BY[$I]}" ]; then
      echo "*** No device found with this UUID: ${CACHED_BY_UUIDS[$I]} ***" 1>&2
      ERROR=1
    fi
  done

  # Do all block devices exist?
  for D in $(sorted_unique ${STORAGE_DEVS[@]} ${CACHED_BY[@]}); do
    if [ ! -b $D ]; then
      echo "*** Not a block device: $D ***" 1>&2
      ERROR=1
    fi
  done

  # Any devices assigned multiple times?
  CACHE_DEVS=$(sorted_unique ${CACHED_BY[@]})
  DUPLICATE_DEVS=$(sorted_duplicates ${STORAGE_DEVS[@]} $CACHE_DEVS)
  if [ "$DUPLICATE_DEVS" ]; then
    echo "*** Devices assigned multiple times: $DUPLICATE_DEVS ***" 1>&2
    ERROR=1
  fi

  # All cache devices non-removable and non-rotational (SSDs)?
  for D in $CACHE_DEVS; do
    if ! is_ssd $D; then
      echo "*** Cache device is not an SSD: $D ***" 1>&2
      ERROR=1
    fi
  done

  # Root file system must not be a swap FS
  if [ ${FS_TYPES[0]} = 'swap' ]; then
    echo "*** Root file system must not be a ${FS_TYPES[0]} file system ***" 1>&2
    ERROR=1
  fi

  # Swap file systems cannot be cached
  for (( I=0; I<$NUM_FS; I++ )); do
    if [ "${FS_TYPES[$I]}" = 'swap' -a -n "${CACHED_BY[$I]}" ]; then
      echo "*** A ${FS_TYPES[$I]} file system cannot be cached: ${STORAGE_DEVS[$I]} ***" 1>&2
      ERROR=1
    fi
  done
 
  # Multiple swap file systems? Only a warning
  if [[ $(sorted_duplicates ${FS_TYPES[@]}) == *swap* ]]; then
    echo "*** Multiple swap file systems prevent hibernation. Consider using a RAID 0. ***" 1>&2
  fi

  # Root mount point for root file system?
  MP=$(sorted_unique ${MOUNT_POINTS[0]})
  if [ "${MP%% *}" != / ]; then
    echo "*** Root file system not at mount point / ***" 1>&2
    ERROR=1
  fi

  # Do the mount points exist as directories?
  for D in $MP; do
    if [ ! -d $D ]; then
      echo "*** Mount point not found on host system: $D ***" 1>&2
      ERROR=1
    fi
  done

  # Any duplicate mount points?
  MP_DUP=$(sorted_duplicates ${MOUNT_POINTS[@]})
  if [ "$MP_DUP" ]; then
    echo "*** Mount points assigned multiple times: $MP_DUP ***" 1>&2
    ERROR=1
  fi

  # Is the key file readable?
  if [ -n "$KEY_FILE" -a ! -r "$KEY_FILE" ]; then
    echo "*** Not a readable file: $KEY_FILE ***" 1>&2
    ERROR=1
  fi

  if [ "$INSTALL_GOAL" ]; then
    # Get host's package repository
    REPO=$(grep -m 1 -o -E 'https?://.*\.(archive\.ubuntu\.com/ubuntu/|releases\.ubuntu\.com/)' /etc/apt/sources.list) \
      die 'No Ubuntu repository URL found in /etc/apt/sources.list'

    # Attempting to cache the boot file system?
    if [ "${CACHED_BY[$BOOT_DEV_INDEX]}" ]; then
      echo "*** The /boot file system must not be cached: ${STORAGE_DEVS[$BOOT_DEV_INDEX]} ***" 1>&2
      ERROR=1
    fi

    # Encrypted boot partition must be using a passphrase (GRUB does not support key files)
    if [ -n "${ENCRYPTED[$BOOT_DEV_INDEX]}" -a -n "$AUTH_METHOD" ] && [ $AUTH_METHOD -gt 1 ]; then
      echo "*** The /boot file system must not be encrypted using a key file: ${STORAGE_DEVS[$BOOT_DEV_INDEX]} ***" 1>&2
      ERROR=1
    fi
  fi

  if [ "$ERROR" ]; then
    if [ "$BATCH_MODE" ]; then
      die 'Invalid configuration'
    else
      read -erp $'\nInvalid configuration, [Enter] to edit: '
      continue
    fi
  fi

  # Show configuration summary only if interactive
  if [ ! "$BATCH_MODE" ]; then

    cat <<- EOF
Configuration summary
=====================

EOF

    ALL_DEVS=$(sorted_unique ${STORAGE_DEVS[@]} ${CACHED_BY[@]})
    ALL_DISKS=$(sorted_unique_disks $ALL_DEVS)

    lsblk -o NAME,FSTYPE,SIZE,LABEL $ALL_DISKS | grep -E "NAME${ALL_DISKS//\/dev\//|^}${ALL_DEVS//\/dev\//|}"
    echo ''

    VOL_HINT="Root file system:       "

    for (( I=0; I<$NUM_FS; I++ )); do
      echo \
        "${VOL_HINT}${STORAGE_DEVS[$I]}"
      [ -n "$INSTALL_GOAL" -a "$I" = "$BOOT_DEV_INDEX" ] && echo \
        "  Boot device"
      [ "${RAID_LEVELS[$I]}" ] && echo \
        "  RAID level:           ${RAID_LEVELS[$I]}"
      if [ "${CACHED_BY[$I]}" ]; then
        echo \
        "  SSD caching device:   ${CACHED_BY[$I]}"
        echo \
        "    Erase block size:   ${ERASE_BLOCK_SIZES[${CACHED_BY[$I]}]}"
      fi
      [ "${ENCRYPTED[$I]}" ] && echo \
        "  LUKS-encrypted"
      echo \
        "  File system type:     ${FS_TYPES[$I]}"
      [ "${MOUNT_POINTS[$I]}" ] && echo \
        "    Mount point(s):     ${MOUNT_POINTS[$I]}"
      [ "${MOUNT_OPTIONS[$I]}" ] && echo \
        "    Mount options:      ${MOUNT_OPTIONS[$I]}"

      VOL_HINT="Additional file system: "
    done

    if [ "$AUTH_METHOD" ]; then
      echo \
        "Authorization method:   ${AUTH_METHODS[$AUTH_METHOD]}"
      [ "$KEY_FILE" ] && echo \
        "Key file:               $KEY_FILE"
    fi

    [ "$PREFIX" ] && echo \
        "Mapper/label prefix:    $PREFIX"

    echo \
      "Target mount point:     $TARGET"

    if [ "$INSTALL_GOAL" ]; then
      echo \
        "Installing:             $DISTRIB_DESCRIPTION"
      echo \
        "Hostname:               $TARGET_HOSTNAME"
    fi

    echo ''

    if [ -n "$BUILD_GOAL" -o -n "$INSTALL_GOAL" ]; then
      echo "*** WARNING: existing data on ${ALL_DEVS// /, } will be overwritten! ***"
      [ "$INSTALL_GOAL" ] && echo "*** WARNING: MBRs on ${BOOT_DEVS// /, } will be overwritten! ***"
      echo ''
    fi
    confirmed "About to $FRIENDLY_GOAL this configuration -- proceed" y || continue
  fi

  # Save configuration
  [ ! -f $CONFIG_FILE ] && echo "Creating configuration file $CONFIG_FILE"
  sudo --user=$SUDO_USER truncate -s 0 $CONFIG_FILE
  for V in TARGET NUM_FS STORAGE_DEVS STORAGE_DEVS_UUIDS RAID_LEVELS CACHED_BY CACHED_BY_UUIDS \
      ERASE_BLOCK_SIZES ENCRYPTED FS_TYPES MOUNT_POINTS MOUNT_OPTIONS \
      AUTH_METHOD KEY_FILE KEY_FILE_SIZE PREFIX TARGET_HOSTNAME; do
    echo "$(declare -p $V)" >> $CONFIG_FILE
  done

  # For encryption, save the LUKS key to the keyring
  if [ -n "$BUILD_GOAL" -o -n "$MOUNT_GOAL" ]; then
    KEY_DESC="key:$CONFIG_FILE"

    case $AUTH_METHOD in
      1)
        # Save passphrase to keyring, passphrase == key
        PROMPT=
        [ "$BUILD_GOAL" ] && PROMPT='  Enter new passphrase: '
        [ "$KEY_ID" ] || KEY_ID=$(read_passphrase "$PROMPT")
        ;;

      2)
        # Save key file content to keyring
        KEY_ID=$(cat "$KEY_FILE" | keyctl padd user "$KEY_DESC" @u)
        on_exit "Revoking LUKS key" "keyctl revoke $KEY_ID"
        ;;

      3)
        # Save decrypted key file content to keyring
        while true; do
          [ "$PW_ID" ] || PW_ID=$(read_passphrase)
          KEY_ID=$(cat "$KEY_FILE" | gpg --quiet --yes --passphrase "$(keyctl pipe $PW_ID)" --output - | keyctl padd user "$KEY_DESC" @u 2>/dev/null) && break
          PW_ID=
        done
        
        on_exit "Revoking LUKS key" "keyctl revoke $KEY_ID"
        ;;
    esac
  fi

  break
done

# Disable udev rules (bcache rule interferes with setup)
echo "Disabling 'other' udev rules"
udevadm control --property=DM_UDEV_DISABLE_OTHER_RULES_FLAG=1
on_exit "Re-enabling 'other' udev rules" 'udevadm control --property=DM_UDEV_DISABLE_OTHER_RULES_FLAG='

# Before building/mounting: stop encryption, caches and RAIDs in reverse order
DEVS_TO_UNLOCK=
for (( I=${#STORAGE_DEVS[@]}-1; I>=0; I-- )); do
  DEVS_TO_UNLOCK="$DEVS_TO_UNLOCK ${STORAGE_DEVS[$I]}"
done

DEVS_TO_UNLOCK="$DEVS_TO_UNLOCK $(sorted_unique ${CACHED_BY[@]})"
DEVS_TO_UNLOCK=${DEVS_TO_UNLOCK//\/dev\//}

cleanup $DEVS_TO_UNLOCK
[ -d $TARGET -a -n "$(ls -A $TARGET)" ] && die "$TARGET is not empty"

if [ "$UNMOUNT_GOAL" ]; then
  echo $'\n'"Storage unmounted from $TARGET"
  exit
fi

# Prepare for file system testing
install_pkg -t fio


# ---------------------- Set up the file system ----------------------------

# RAID arrays
declare -a FS_DEVS
declare -a LABELS

for (( I=0; I<$NUM_FS; I++ )); do
  # Sort mount points by increasing directory depth so that the root mount point is first, if present
  MOUNT_POINTS[$I]=$(sorted_unique ${MOUNT_POINTS[$I]})

  # Use the (first) mount point or the file system type as label
  MP_RE='^[[:space:]]*/([^[:space:]]*)'
  [[ "${MOUNT_POINTS[$I]}" =~ $MP_RE ]] && LABEL="${BASH_REMATCH[1]}" || LABEL=${FS_TYPES[$I]}
  LABEL=${LABEL//\//-}
  [ "$LABEL" ] || LABEL=root
  LABELS[$I]=$LABEL

  if [ "${RAID_LEVELS[$I]}" ]; then
    install_pkg -t mdadm smartmontools

    MD_DEV=$(new_path /dev/md/${PREFIX}${LABEL})
    FS_DEVS[$I]=$MD_DEV

    NUM_DEVS=(${STORAGE_DEVS[$I]})
    NUM_DEVS=${#NUM_DEVS[@]}

    if [ "$BUILD_GOAL" ]; then
      echo "Creating RAID $MD_DEV on homehost $TARGET_HOSTNAME from components ${STORAGE_DEVS[$I]// /, }"

      # Mixed SSD/HDD array?
      SSD_DEVS=
      HDD_DEVS=

      for D in ${STORAGE_DEVS[$I]}; do
        if [ $D = /dev/sde2 ]; then
        #if is_ssd $D; then
          SSD_DEVS="$SSD_DEVS $D"
        else
          HDD_DEVS="$HDD_DEVS $D"
        fi
      done

      SSD_DEVS=${SSD_DEVS/ /}
      HDD_DEVS=${HDD_DEVS/ /}

      wipefs -a ${STORAGE_DEVS[$I]}
      if [ ${RAID_LEVELS[$I]} -eq 1 -a -n "$SSD_DEVS" -a -n "$HDD_DEVS" ]; then
        # Mixed SSD/HDD RAID1 array, prefer reading from SSD
        echo "Will prefer reading from ${SSD_DEVS// /, }, writing-behind to ${HDD_DEVS// /, }"
        yes | mdadm --quiet --create $MD_DEV --level=${RAID_LEVELS[$I]} --homehost=$TARGET_HOSTNAME --raid-devices=$NUM_DEVS $SSD_DEVS --write-behind --bitmap=internal --write-mostly $HDD_DEVS

      else
        # SSD-only/HDD-only array
        yes | mdadm --quiet --create $MD_DEV --level=${RAID_LEVELS[$I]} --homehost=$TARGET_HOSTNAME --raid-devices=$NUM_DEVS ${STORAGE_DEVS[$I]}
      fi

    elif [ "$MOUNT_GOAL" ]; then
      echo "Assembling RAID $MD_DEV from components ${STORAGE_DEVS[$I]}"
      mdadm --quiet --assemble $MD_DEV ${STORAGE_DEVS[$I]}
    fi

    # Adjust drive/driver error timeouts on host
    . "$HERE/${SCRIPT_NAME}.mdraid-helper" $MD_DEV

    # Prevent RAIDs from being mistaken as SSDs by btrfs
    [ ${FS_TYPES[$I]} = btrfs ] && MOUNT_OPTIONS[$I]="nossd,${MOUNT_OPTIONS[$I]}"

  else
    FS_DEVS[$I]=${STORAGE_DEVS[$I]}
  fi
done


# Cache devices
declare -A CSET_UUIDS

for D in $(sorted_unique ${CACHED_BY[@]}); do
  install_pkg -t bcache-tools
  modprobe bcache

  if [ "$BUILD_GOAL" ]; then
    echo "Creating cache device $D"
    wipefs -a $D
    sleep 1
    CSET_RE='Set UUID:[[:space:]]*([^[:space:]]+)'
    [[ $(make-bcache -b ${ERASE_BLOCK_SIZES[$D]} -C $D) =~ $CSET_RE ]] || die "Unexepected output format of make-bcache"

  elif [ "$MOUNT_GOAL" ]; then
    echo "Registering cache device $D"
    CSET_RE='cset.uuid[[:space:]]+([^[:space:]]+)'
    [[ $(bcache-super-show $D) =~ $CSET_RE ]] || die "Unexepected output format of bcache-super-show"
  fi

  echo $D > /sys/fs/bcache/register 2>/dev/null || true
  CSET_UUIDS[$D]=${BASH_REMATCH[1]}
  wait_file /sys/fs/bcache/${CSET_UUIDS[$D]}
done

# Backing devices
declare -A CSET_FOR
declare -A BACKING_FOR

for (( I=0; I<$NUM_FS; I++ )); do
  CACHE_DEV=${CACHED_BY[$I]}
  if [ "$CACHE_DEV" ]; then
    CSET_UUID=${CSET_UUIDS[$CACHE_DEV]}
    D=${FS_DEVS[$I]}

    if [ "$BUILD_GOAL" ]; then
      echo "Configuring $D as backing device"
      wipefs -a $D
      make-bcache -B $(readlink -e $D)

      CSET_FOR[$D]=$CSET_UUID
      BACKING_FOR[$CSET_UUID]="${BACKING_FOR[$CSET_UUID]} $D"
    fi

    echo "Attaching $D to cache device $CACHE_DEV"
    dev_dirs $D
    echo $D > /sys/fs/bcache/register 2>/dev/null || true
    wait_file $BCACHE_DIR/attach
    echo $CSET_UUID > $BCACHE_DIR/attach
    sleep 1
    FS_DEVS[$I]=/dev/$(basename $(readlink -e $BCACHE_DIR/dev))
    [ -b ${FS_DEVS[$I]} ] || die "Should be a block device: ${FS_DEVS[$I]}"
  fi
done

# Cache/backing device relationships
BCACHE_HINTS="# generated by $SCRIPT_NAME on $(date --rfc-3339=seconds)"

for D in ${!CSET_FOR[@]}; do
  C=${CSET_FOR[$D]}
  D=$(dev_to_uuid $D)
  D=cset_for_backing_uuid_${D//-/_}
  BCACHE_HINTS="$BCACHE_HINTS\n$D=$C"
done

for C in ${!BACKING_FOR[@]}; do
  D=$(devs_to_disks_by_uuid ${BACKING_FOR[$C]})
  D=${D//\/dev\/disk\/by-uuid\//}
  C=backing_uuids_for_cset_${C//-/_}
  BCACHE_HINTS="$BCACHE_HINTS\n$C='$D'"
done


# LUKS encryption
for (( I=0; I<$NUM_FS; I++ )); do
  if [ "${ENCRYPTED[$I]}" ]; then
    install_pkg -t cryptsetup gnupg keyutils

    # Avoid name conflicts with existing LUKS devices
    MAPPED_DEV=$(new_path /dev/mapper/${PREFIX}luks-${LABELS[$I]})
    MAPPED=${MAPPED_DEV#/dev/mapper/}
    LUKS_DEV=${FS_DEVS[$I]}
    echo "Mapping LUKS device $LUKS_DEV to $MAPPED_DEV"
    [ "$BUILD_GOAL" ] && format_luks $LUKS_DEV $MAPPED
    keyctl pipe $KEY_ID | cryptsetup --key-file - luksOpen $LUKS_DEV $MAPPED
    FS_DEVS[$I]=$MAPPED_DEV
  fi
done

# Create file systems
if [ "$BUILD_GOAL" ]; then
  for (( I=0; I<$NUM_FS; I++ )); do
    FS_DEV=${FS_DEVS[$I]}
    FS_TYPE=${FS_TYPES[$I]}
    LABEL=${LABELS[$I]}
    MP=(${MOUNT_POINTS[$I]})
    MO=${MOUNT_OPTIONS[$I]}

    echo "Formatting $FS_DEV (volume ${PREFIX}${LABEL}) as $FS_TYPE"
    wipefs -a $FS_DEV
    
    case $FS_TYPE in
      ext*|xfs)
        [ $FS_TYPE = xfs ] && install_pkg -t xfsprogs
        mkfs.$FS_TYPE -L ${PREFIX}${LABEL} $FS_DEV
        sleep 1
        [ $MP = / ] && PASS=1 || PASS=2
        add_fstab $FS_DEV $MP $FS_TYPE "$MO" $PASS
        ;;

      btrfs)
        install_pkg -t btrfs-tools
        mkfs.btrfs -L ${PREFIX}${LABEL} -m dup $FS_DEV

        echo "Creating subvolume(s) ${MP[@]/\//@} for $FS_DEV"
        TMP_MP=$(mktemp -d)
        on_exit "Removing temporary mount point $TMP_MP", "rmdir $TMP_MP"
        mount $FS_DEV ${TMP_MP}/

        for M in ${MP[@]}; do
          SUBVOL=${M/\//@}
          btrfs subvolume create ${TMP_MP}/${SUBVOL}
          sleep 1
          [ $M = / ] && PASS=1 || PASS=2
          add_fstab $FS_DEV $M btrfs "subvol=$SUBVOL,$MO" $PASS
        done
        umount $FS_DEV
        ;;

      swap)
        mkswap -L ${PREFIX}${LABEL} $FS_DEV
        sleep 1
        add_fstab $FS_DEV none swap sw 0
        ;;

      *)
        die "Cannot create this type of file system: $FS_TYPE"
        ;;
    esac
  done
fi

# Mount file systems, parent directories first
for MP in $(sorted_unique ${MOUNT_POINTS[@]}); do
  # Search for file system with matching mount point
  for (( I=0; I<$NUM_FS; I++ )); do
    if contains_word "${MOUNT_POINTS[$I]}" "$MP"; then
      FS_DEV=${FS_DEVS[$I]}
      FS_TYPE=${FS_TYPES[$I]}
      MO=${MOUNT_OPTIONS[$I]}

      case $FS_TYPE in
        ext*|xfs)
          echo "Mounting $FS_DEV at $TARGET$MP"
          mkdir -p $TARGET$MP
          mount -o "$MO" $FS_DEV $TARGET$MP
          ;;

        btrfs)
          # Mount subvolume
          echo "Mounting $FS_DEV subvolume ${MP/\//@} at $TARGET$MP"
          mkdir -p $TARGET$MP
          mount -o subvol=${MP/\//@},$MO $FS_DEV $TARGET$MP
          ;;

        *)
          die "Cannot mount this type of file system: $FS_TYPE"
          ;;
      esac
    fi
  done
done

# Update UUIDs in configuration file after build
if [ "$BUILD_GOAL" ]; then
  declare -a STORAGE_DEVS_UUIDS
  declare -a CACHED_BY_UUIDS

  for (( I=0; I<$NUM_FS; I++ )); do
    # Use only the first device (if it is a RAID then all components have the same UUID)
    VD=(${STORAGE_DEVS[$I]})
    STORAGE_DEVS_UUIDS[$I]=$(dev_to_uuid $VD)
    CACHED_BY_UUIDS[$I]=$(dev_to_uuid ${CACHED_BY[$I]})
  done

  echo "$(declare -p STORAGE_DEVS_UUIDS)" >> $CONFIG_FILE
  echo "$(declare -p CACHED_BY_UUIDS)" >> $CONFIG_FILE
fi

if [ ! "$INSTALL_GOAL" ]; then
  # Mount the target file system for chroot-ing
  mount_devs
  echo $'\n'"Target system mounted at $TARGET and ready to chroot"
  exit
fi


# -------------------- Install and configure target system ---------------

breakpoint "Target file system mounted at $TARGET, about to install a minimal $DISTRIB_DESCRIPTION"

install_pkg debootstrap
debootstrap \
  --arch $(dpkg --print-architecture) \
  --include language-pack-${LANG%%_*} \
  $DISTRIB_CODENAME $TARGET $REPO

breakpoint "Minimal $DISTRIB_DESCRIPTION installed, about to configure target system"

mkdir -p $TARGET/etc/apt
cat > $TARGET/etc/apt/sources.list <<-EOF
# Ubuntu Main Repos
deb $REPO ${DISTRIB_CODENAME} main restricted universe multiverse 
deb $REPO ${DISTRIB_CODENAME}-security main restricted universe multiverse 
deb $REPO ${DISTRIB_CODENAME}-updates main restricted universe multiverse 
deb $REPO ${DISTRIB_CODENAME}-backports main restricted universe multiverse

# Ubuntu Partner Repo
deb http://archive.canonical.com/ubuntu/ ${DISTRIB_CODENAME} partner
EOF

# Create /etc/fstab
mkdir -p $TARGET/etc
echo -e "$FSTAB" > $TARGET/etc/fstab

# Boot-time decryption
if [ "${ENCRYPTED[*]}" ]; then
  # Copy keyscript to initramfs
  mkdir -p ${TARGET}$(dirname $KEY_SCRIPT)
  cp -f "$HERE/${SCRIPT_NAME}.keyscript" ${TARGET}$KEY_SCRIPT
  chmod 700 ${TARGET}$KEY_SCRIPT
  initramfs_hook crypt -c $KEY_SCRIPT -x $(which keyctl) -x $(which gpg) -c /usr/share/gnupg/options.skel

  # Create /etc/crypttab using keyscript authentication
  mkdir -p $TARGET/etc
  echo -e "$CRYPTTAB" > $TARGET/etc/crypttab
fi

# udev rule for RAID arrays
if [ "${RAID_LEVELS[*]}" ]; then
  # Add udev rule to adjust drive/driver error timeouts
  mkdir -p $TARGET/etc/udev/rules.d
  cp -f "$HERE/${SCRIPT_NAME}.mdraid-rule" ${TARGET}$RAID_RULE_FILE
  chmod 644 ${TARGET}$RAID_RULE_FILE

  # Copy udev helper script to initramfs
  mkdir -p ${TARGET}$(dirname $RAID_HELPER_FILE)
  cp -f "$HERE/${SCRIPT_NAME}.mdraid-helper" ${TARGET}$RAID_HELPER_FILE
  chmod 755 ${TARGET}$RAID_HELPER_FILE

  initramfs_hook mdraid-helper -c $RAID_RULE_FILE -c $RAID_HELPER_FILE -x $(which smartctl)
fi

# Standard bcache udev rule seems to fail sometimes for RAIDs, therefore ...
if [ -n "${RAID_LEVELS[*]}" -a -n "${CACHED_BY[*]}" ]; then
  # Override default udev rule with custom rule
  BCACHE_RULE_FILE=/etc/udev/rules.d/$(find /lib/udev/rules.d/ -name '*-bcache.rules' -type f -printf '%P')
  mkdir -p $TARGET/etc/udev/rules.d
  cp -f "$HERE/${SCRIPT_NAME}.bcache-rule" ${TARGET}$BCACHE_RULE_FILE
  chmod 644 ${TARGET}$BCACHE_RULE_FILE

  # Copy udev helper script to initramfs
  mkdir -p ${TARGET}$(dirname $BCACHE_HELPER_FILE)
  cp -f "$HERE/${SCRIPT_NAME}.bcache-helper" ${TARGET}$BCACHE_HELPER_FILE
  chmod 755 ${TARGET}$BCACHE_HELPER_FILE
  echo -e "$BCACHE_HINTS" > ${TARGET}$BCACHE_HINT_FILE
  chmod 644 ${TARGET}$BCACHE_HINT_FILE

  initramfs_hook bcache-helper -c $BCACHE_RULE_FILE -c $BCACHE_HELPER_FILE -c $BCACHE_HINT_FILE -x $(which bcache-super-show)
fi

# Copy debconf settings from host
install_pkg debconf-utils
mkdir -p ${TARGET}/tmp
DEBCONF=$(mktemp ${TARGET}/tmp/debconfXXXX.tmp)
on_exit "Removing ${TARGET}/tmp/"'*' "rm -rf ${TARGET}/tmp/"'*'
debconf-get-selections | grep -E '^(tzdata|keyboard-configuration|console-data|console-setup)[[:space:]]' >$DEBCONF
cp -fpR /etc/{localtime,timezone} /etc/default /etc/console-setup ${TARGET}/tmp

# chroot into the installation target
mount_devs
echo "Configuring target system: chroot into $TARGET"
SUDO_PW=$(grep $SUDO_USER /etc/shadow | cut --delimiter ':' --fields 2)

if chroot $TARGET /bin/bash -l <<- EOF
	set -e +x

	LC=${LANG%%_*}
	export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true

	# Upgrade to the latest kernel version
	apt-get -y -q update
	apt-get -y -q upgrade
	apt-get -y -q --reinstall --no-install-recommends install linux-image-generic linux-headers-generic linux-tools-generic

	# Set hostname
	echo '$TARGET_HOSTNAME' > /etc/hostname
	echo -e 'PRETTY_HOSTNAME=$TARGET_HOSTNAME\nICON_NAME=computer\nCHASSIS=desktop\nDEPLOYMENT=production' > /etc/machine-info
	sed -e 's/localhost/localhost $TARGET_HOSTNAME/' -i /etc/hosts

	# Configure locale, timezone, console and keyboard
	locale-gen $LANG
	apt-get -y -q --no-install-recommends install \
	  network-manager nano man-db plymouth-themes console-data console-setup bash-completion
	  
	update-locale LANG=$LANG LC_{ADDRESS,ALL,COLLATE,CTYPE,IDENTIFICATION,MEASUREMENT,MESSAGES,MONETARY,NAME,NUMERIC,PAPER,RESPONSE,TELEPHONE,TIME}=$LANG

	cp -fp /tmp/{localtime,timezone} /etc
	cp -fp /tmp/default/{keyboard,console-setup} /etc/default
	cp -fpR /tmp/console-setup /etc
	
	debconf-set-selections $DEBCONF
	for P in tzdata keyboard-configuration console-data console-setup; do
	  dpkg-reconfigure -f noninteractive \$P
	done

	# Copy current (non-sudo) user from host
	echo 'Copying user $SUDO_USER'
	useradd --create-home --groups adm,dialout,cdrom,floppy,sudo,audio,dip,video,plugdev,games,netdev --shell /bin/bash $SUDO_USER
	echo '$SUDO_USER:$SUDO_PW' | chpasswd -e

	# Install packages required for file system
	echo 'Installing additional packages'
	apt-get -y -q --no-install-recommends install $(sorted_unique $TARGET_PKGS)

	# Install and configure boot loader
	DEBIAN_FRONTEND=noninteractive apt-get -y -q --no-install-recommends install grub-pc os-prober

  # GRUB keyboard layout not localized because of questionable benefit, see these links for instructions:
  # http://askubuntu.com/questions/751259/how-to-change-grub-command-line-grub-shell-keyboard-layout#answer-751260
  # https://wiki.archlinux.org/index.php/Talk:GRUB#Custom_keyboard_layout

	cat >> /etc/default/grub <<-XEOF
GRUB_CMDLINE_LINUX="\\\$GRUB_CMDLINE_LINUX locale=\${LANG%%.*} bootkbd=\$LC console-setup/layoutcode=\$LC"
GRUB_GFXMODE=1024x768
XEOF

	# Honor debug options
	case "$DEBUG_MODE" in
	  1)
	    # -d: disable os-prober
	    cat >> /etc/default/grub <<-XEOF
GRUB_CMDLINE_LINUX_DEFAULT=
GRUB_DISABLE_OS_PROBER=true
XEOF
	    ;;
	  2)
	    # -dd: disable os-prober, drop into initramfs
	    cat >> /etc/default/grub <<-XEOF
# To drop into initramfs: break=top|modules|premount|mount|mountroot|bottom|init
GRUB_CMDLINE_LINUX="\\\$GRUB_CMDLINE_LINUX break=mount"
GRUB_CMDLINE_LINUX_DEFAULT=
GRUB_DISABLE_OS_PROBER=true
XEOF
	    ;;
	  *)
	    # Always disable splash
	    cat >> /etc/default/grub <<-XEOF
GRUB_CMDLINE_LINUX_DEFAULT=quiet
XEOF
	    ;;
	esac

	update-initramfs -c -k all
	update-grub

	# Install boot loader on all devices that comprise /boot
	for B in ${STORAGE_DEVS[$BOOT_DEV_INDEX]}; do
	  B=\${B%%[1-9]*}
	  echo 'Installing boot loader on '\$B
	  grub-install \$B
	done
EOF

then
  echo 'Installation finished'

else
  echo "*** Target system configuration failed ***" 1>&2
fi

echo $'\n'"Target system mounted at $TARGET and ready to chroot"
