#!/bin/bash

# StorageComposer
# ===============
#
# A script for creating and managing hard disk storage under Ubuntu, from
# simple situations (single partition) to complex ones (multiple drives/partitions, 
# different file systems, encryption, RAID and SSD caching in almost any combination).
#
# This script can also install a basic Ubuntu and make the storage bootable.
#
# Copyright 2016-2018 Ferdinand Kasper, fkasper@modus-operandi.at
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
HERE=$(dirname $(readlink -e $0))
SCRIPT_NAME=$(basename -s .sh $0)

# Saved configuration
DEFAULT_CONFIG_FILE=$HOME/.${SCRIPT_NAME}.conf
CONFIG_FILE=$DEFAULT_CONFIG_FILE

# Passphrase expiration time in keyring, SSH master connection timeout (in s)
PW_EXPIRATION=300

# Absolute path to initramfs keyscript in target system
KEY_SCRIPT=/usr/local/sbin/keyscript

# RAID udev rule for adjusting drive/driver error timeouts
RAID_HELPER_FILE=/usr/local/sbin/mdraid-helper
RAID_RULE_FILE=/etc/udev/rules.d/90-mdraid.rules

# Replacement for standard udev bcache rule
BCACHE_HELPER_FILE=/usr/local/sbin/bcache-helper
BCACHE_HINT_FILE=$(dirname $BCACHE_HELPER_FILE)/bcache-hints

# Friendly names of authorization methods (0 is unused)
AUTH_METHODS=('' 'passphrase' 'key file' 'encrypted key file')

# Default mount options for each of the available file system types,
# applied to host mounts and to target system
declare -A DEFAULT_MOUNT_OPTION_MAP=( \
  [ext2]=defaults,relatime,errors=remount-ro \
  [ext3]=defaults,relatime,errors=remount-ro \
  [ext4]=defaults,relatime,errors=remount-ro \
  [btrfs]=defaults,relatime \
  [xfs]=defaults,relatime \
  [swap]= \
)

# Maximum waiting time until a device, file etc. becomes available (in s)
MAX_WAIT=30

# Regexp for an empty or blank string
BLANK_RE='^[[:space:]]*$'


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

require_pkg() {
  local TARGET_OPT
  if [ "$1" = '-t' ]; then
    TARGET_OPT=1
    shift
  fi

  for P; do
    dpkg -L "$P" >/dev/null 2>&1 || apt-get --no-install-recommends -q -y install "$P" >/dev/null
  done

  [ -n "$TARGET_OPT" ] && TARGET_PKGS="$TARGET_PKGS $@" || true
}


# --------------------------------------------------------------------------

# Displays a message on stdout; pauses this script if in $DEBUG_MODE.
#
# Arguments:
#   $1           message to display
#   $DEBUG_MODE  enables breakpoints if non-empty
#
breakpoint() {
  echo $'\n*** '"$1"
  if [ "$DEBUG_MODE" ]; then
    local REPLY
    read -rp $'\n[Enter] to continue or Ctrl-C to abort: '
  fi
}


# --------------------------------------------------------------------------

# Prints a message to sterr, triggers SIGERR and terminates this script
# with exit code 1.
#
# Arguments:
#   $1  error message
#
die() {
  echo $'\n'"****** FATAL: $1 ******"$'\n' 1>&2

  # Trigger SIGERR and _exit_
  set -e
  return 1
}


# --------------------------------------------------------------------------

# Prints an error message to stderr and sets the global error indicator
# $ERROR to non-empty.
#
# Arguments:
#   $1  error message
ERROR=

error() {
  echo "*** $1 ***" 1>&2
  ERROR=1
}


# --------------------------------------------------------------------------

# Add a line feed and a warning message to the global $WARNINGS.
#
# Arguments:
#   $1  warning message
#
WARNINGS=

warning() {
  WARNINGS="$WARNINGS"$'\n'"*** $1 ***"
}


# --------------------------------------------------------------------------

# Prints an information message to stdout.
#
# Arguments:
#   $1  info message
#
info() {
  echo "--- $1"
}


# --------------------------------------------------------------------------

# Saves command groups that will be run on exit. Commands groups will be
# run in reverse order; commands within a command group are run in-order. 
#
# Arguments:
#   $1           description of command group, printed at stdout before
#                command group runs
#   $2, $3, ...  group of commands to be run on exit
#
EXIT_SCRIPT=

on_exit() {
  if [ ! -f "$EXIT_SCRIPT" ]; then
    # Prepare the cleanup script
    EXIT_SCRIPT=$(mktemp --tmpdir)
    trap "{ set +e; tac $EXIT_SCRIPT | . /dev/stdin; rm $EXIT_SCRIPT; exit; }" EXIT
  fi

  local DESC=$1
  shift 1
  local CMDS=("$@")
  local I

  for ((I=${#CMDS[@]}-1; I>=0; I--)); do
    echo "${CMDS[$I]}" >> $EXIT_SCRIPT
  done

  echo "echo '--- $DESC'" >> $EXIT_SCRIPT
}


# --------------------------------------------------------------------------

# Prompts for text input and verifies that the text is not empty and  
# is contained in a list of valid values (optional). Spaces are removed 
# from the text. Prints the text to stdout. Error messages go to stderr.
#
# Arguments:
#   $1           prompt
#   $2           default value (optional)
#   $3           space-delimited list of valid value regexps (optional)
#   $BATCH_MODE  non-empty if running not interactively
# Calls:
#   die
#
read_text() {
  [ "$BATCH_MODE" ] && die "Cannot enter '$1' in batch mode"

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
      echo "*** Input must match one of: ${3// /, } ***" 1>&2
    fi
  done

  echo -n "$REPLY"
}


# --------------------------------------------------------------------------

# Prompts for an integer and prints that it to stdout. Accepts binary units
# K, M, G and T as suffixes. Limits may be specified, also with suffixes. 
# Use to_int() to convert the result to a numeric value.
# Error messages go to stderr.
#
# Arguments:
#   $1           prompt
#   $2           default value (optional)
#   $3           lower limit (optional)
#   $4           upper limit (optional)
#   $BATCH_MODE  non-empty if running not interactively
# Results:
#   INT_REPLY    numeric value 
# Calls:
#   to_int, die
#
read_int() {
  [ "$BATCH_MODE" ] && die "Cannot enter '$1' in batch mode"

  local REPLY
  local INT_REPLY
  local MIN
  local MAX

  [ ! "$3" ] || MIN=$(to_int "$3") || die "Not an integer: $3"
  [ ! "$4" ] || MAX=$(to_int "$4") || die "Not an integer: $4"

  while true; do
    read -erp "$1" -i "$2"

    if INT_REPLY=$(to_int "$REPLY"); then
      if [ -n "$3" ] && [ "$INT_REPLY" -lt $MIN ]; then
        echo "*** Value must be >= $3 ***" 1>&2
      elif [ -n "$4" ] && [ "$INT_REPLY" -gt $MAX ]; then
        echo "*** Value must be <= $4 ***" 1>&2
      else
        break
      fi
    else
      echo "*** Not an integer, or unknown unit: $REPLY ***" 1>&2
    fi
  done

  echo -n "$REPLY"
}


# --------------------------------------------------------------------------

# Ensures that the keyring contains a passphrase for the current 
# authorization method of the current configuration file and prints the
# passphrase ID to stdout. Error messages go to stderr.
# If the keyring contains a passphrase for the current $CONFIG_FILE and
# $AUTH_METHOD then the user may enter a new passphrase or keep the current
# one. Otherwise, the user *must* enter a passphrase. Optionally, the user
# can be prompted to retype the passphrase for validation.
#
# Arguments:
#   $1              initial passphrase prompt (without indentation and
#                   without trailing ': ')
#   $2              non-empty to request retyping the passphrase for
#                   verification
#   $CONFIG_FILE    name of configuration file
#   $AUTH_METHOD    authorization method (1..3)
#   $PW_EXPIRATION  passphrase expiration time (in s, from last call of this
#                   function)
#   $BATCH_MODE     non-empty if running not interactively
# Calls:
#   require_pkg, die
#
read_passphrase() {
  require_pkg keyutils

  local PW_DESC="pw:$CONFIG_FILE:$AUTH_METHOD"
  local ID
  local REPLY
  local PW

  # Repeat only if the passphrase expires while in this loop
  while true; do
    ID=$(keyctl search @s user "$PW_DESC" 2>/dev/null)

    # In batch mode, use the cached passphrase if available
    if [ "$BATCH_MODE" ]; then
      [ "$ID" ] && break
      die "Cannot enter '$1' in batch mode"
    fi

    local PROMPT="  $1"
    [ "$ID" ] && PROMPT="$PROMPT (empty for previous one)"

    # Prompt for passphrase
    read -rsp "$PROMPT: "
    echo '' 1>&2

    # No cached passphrase available, or a new one entered?
    if [ -z "$ID" -o -n "$REPLY" ]; then
      # Prompt for verification if so requested
      while [ "$2" ]; do
        PW="$REPLY"
        read -rsp '  Repeat passphrase: '
        echo '' 1>&2
        [ "$REPLY" = "$PW" ] && break

        echo '  *** Passphrases do not match ***' 1>&2
        read -rsp "$PROMPT: "
        echo '' 1>&2
      done

      # Save (verified) passphrase to keyring
      ID=$(echo -n "$REPLY" | keyctl padd user "$PW_DESC" @s 2>/dev/null)
    fi
    
    # Repeat if passphrase expired while in this loop
    keyctl timeout $ID $PW_EXPIRATION 2>/dev/null && break
    echo '  *** Previous passphrase expired ***' 1>&2
  done

  echo -n $ID
}


# --------------------------------------------------------------------------

# Reads and verifies a login passphrase on stdin and prints the SHA512 hash
# to stdout. Error messages go to stderr.
# If a passphrase hash was specified then the user may also accept this
# passphrase; otherwise, he must enter and verify a new one.
#
# Arguments:
#   $1              default passphrase hash (optional)
#   $BATCH_MODE     non-empty if running not interactively
# Calls:
#   require_pkg, die
#
read_login() {
  [ "$BATCH_MODE" ] && die 'Cannot enter a login passphrase in batch mode'

  require_pkg whois

  local PROMPT='  Login passphrase: '
  [ "$1" ] && PROMPT='  Login passphrase (empty to leave unchanged): '
  local REPLY
  local PREV_REPLY

  while true; do
    while true; do
      read -rsp "$PROMPT"
      echo '' 1>&2
      [ "$REPLY" ] && break
      [ -n "$1" ] && echo -n "$1" && return
      echo '  *** Passphrase must not be empty ***' 1>&2
    done
    PREV_REPLY="$REPLY"

    read -rsp '  Repeat passphrase: '
    echo '' 1>&2
    [ "$PREV_REPLY" = "$REPLY" ] && break
    echo '  *** Passphrases do not match ***' 1>&2
  done

  echo -n "$REPLY" | mkpasswd -s -m sha-512
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
# Calls:
#   die
#
read_filepath() {
  [ "$BATCH_MODE" ] && die "Cannot enter '$1' in batch mode"

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

# Prompts for one or several absolute directory paths and can verify that 
# they exist. Prints the directory paths to stdout. Error messages go to 
# stderr.
#
# Arguments:
#   $1           prompt
#   $2           default value (optional)
#   $3           allows entering multiple paths if present and non-empty (optional)
#   $4           verifies that directories exist if present and non-empty (optional)
#   $BATCH_MODE  non-empty if running not interactively
# Calls:
#   die
#
read_dirpaths() {
  [ "$BATCH_MODE" ] && die "Cannot enter '$1' in batch mode"

  local DEFAULT=$2
  local REPLY
  local PATHS=

  until [ "$PATHS" ]; do
    read -erp "$1" -i "$DEFAULT"

    I=0
    for P in $REPLY; do
      I=$(($I+1))

      if [ $I -gt 1 -a -z "$3" ]; then
        echo "*** Only one path may be entered ***" 1>&2

      elif [[ "$P" != /* ]]; then
        echo "*** Not an absolute path: $P ***" 1>&2

      elif [ -n "$4" -a ! -d "$P" ]; then
        echo "*** Not a directory: $P ***" 1>&2

      else
        # Path is valid, remove trailing slash
        [ "$P" != '/' ] && P=${P%/}
        PATHS="$PATHS $P"
        continue
      fi

      # Invalid path, repeat input
      DEFAULT="$REPLY"
      PATHS=
      continue 2
    done
  done

  echo -n "${PATHS/ /}"
}


# --------------------------------------------------------------------------

# Prompts for one or several block devices and prints the selection as
# space-delimted device paths to stdout. For brevity, the leading
# '/dev/' path components may be omitted.They will be added to the output
# if necessary.  Only unmounted devices having no holders are allowed.
# Duplicates are considered invalid. Error messages go to stderr.
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
#   available_devs, contains_word, sorted_duplicates, die
#
read_devs() {
  [ "$BATCH_MODE" ] && die "Cannot reply to '$1' in batch mode"

  local AVAILABLE_DEVS="$(available_devs $BUILD_GOAL$MOUNT_GOAL)"
  local SELECTION=
  local DEFAULT=$2
  local REPLY
  local DUPLICATES
  
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

      elif ! contains_word $P $AVAILABLE_DEVS; then
        echo "*** Device is mounted or has a holder or is unknown: $P ***" 1>&2

      else
        # Valid device
        SELECTION="$SELECTION $P"
        continue
      fi

      # Invalid device, repeat input
      DEFAULT="$REPLY"
      SELECTION=
      continue 2
    done

    # Check for duplicates
    DUPLICATES=$(sorted_duplicates $SELECTION)
    if [ "$DUPLICATES" ]; then
      echo "*** Duplicate devices: ${DUPLICATES// /, } ***" 1>&2
      DEFAULT="$REPLY"
      SELECTION=
    fi
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
# Calls:
#   die
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

# Prints a signed integer number to stdout which may be suffixed with a
# binary unit such as K, M, G or T. Returns 1 if the argument is invalid.
#
# Arguments:
#   $1  integer number; sign and binary unit are optional
#
to_int() {
  shopt -s nocasematch
  local INT_RE='^([+-]?)([0-9]+)([KMGT]?)$'

  if [[ "$1" =~ $INT_RE ]]; then
    local SIGN=${BASH_REMATCH[1]}
    local VALUE=${BASH_REMATCH[2]}
    local SUFFIX=${BASH_REMATCH[3]}

    for S in '' K M G T; do
      local S_RE='^'$S'$'
      [[ "$SUFFIX" =~ $S_RE ]] && break
      VALUE=$(( VALUE * 1024 ))
    done
    
    echo -n ${SIGN}${VALUE}

  else
    return 1
  fi
}


# --------------------------------------------------------------------------

# Prints the number of words in a list to stdout.
#
# Arguments:
#   $1, $2, $3, ...  (space-delimited lists of) words
#
num_words() {
  local WORDS=($*)
  echo -n ${#WORDS[*]}
}


# --------------------------------------------------------------------------

# Returns status 0 iff a white-space-delimited list contains a certain word.
#
# Arguments:
#   $1               word to search for
#   $2, $3, $4, ...  (space-delimited lists of) words
#
contains_word() {
  local WORD="$1"
  shift
  [[ "$*" =~ (^|[[:space:]]+)"$WORD"($|[[:space:]]+) ]]
}


# --------------------------------------------------------------------------

# Prints to stdout a list of RAID levels which can be achieved with as many
# components as are specified as arguments. The components do not have to
# exist, only the argument count is relevant.
#
# Arguments:
#   $1, $2, $3, ...  RAID components
#

# RAID levels available for 0...4 components
AVAILABLE_RAID_LEVELS=('' '' '0 1' '0 1 4 5' '0 1 4 5 6 10')

raid_levels_for() {
  local NUM_DEVS=$(($# < ${#AVAILABLE_RAID_LEVELS[@]} ? $# : ${#AVAILABLE_RAID_LEVELS[@]} - 1))
  echo -n "${AVAILABLE_RAID_LEVELS[$NUM_DEVS]}"
}


# --------------------------------------------------------------------------

# Sorts the specified words, removes duplicates and prints the result to
# stdout.
#
# Arguments:
#   $1, $2, $3, ...  (space-delimited lists of) words
#
sorted_unique() {
  echo $* | xargs -n1 | sort -u | xargs
}


# --------------------------------------------------------------------------

# Finds the disks of the specified partitions, removes duplicate disks and
# prints the sorted result to stdout.
#
# Arguments:
#   $1, $2, $3, ...  (space-delimited lists of) partitions (/dev/*[1-9])
#
sorted_unique_disks() {
  echo $* | xargs -n1 | sed -r -e 's/[1-9].*$//' | sort -u | xargs
}


# --------------------------------------------------------------------------

# Sorts the specified words and prints only the duplicates to stdout.
#
# Arguments:
#   $1, $2, $3, ...  (space-delimited lists of) words
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
  local AVAILABLE_DEVS=$(ls /dev/sd?[1-9]*)
  
  if [ "$1" ]; then
    local D

    for D in $AVAILABLE_DEVS; do
      dev_dirs $D   
      [ -z "$(/bin/ls -A $HOLDERS_DIR)" ] \
        && ! contains_word $D $(cat /proc/mounts) \
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
  declare -g DEV_DIR=$(find -L /sys/block -maxdepth 2 -type d -name $(basename $(readlink -e $1)))
  declare -g BCACHE_DIR=$DEV_DIR/bcache
  declare -g HOLDERS_DIR=$DEV_DIR/holders
}


# --------------------------------------------------------------------------

# Prints to stdout the partition UUID for each block device that was passed
# as an argument. Block devices for which no partition UUID was found are
# printed as-is.
#
# Arguments:
#   $1, $2, $3, ...  block devices (/dev/sd*)
#
devs_to_parts() {
  local D
  local UUIDS=
  local LSBLK=$(lsblk -n -o NAME,PARTUUID -d /dev/sd[a-z]?* || true)

  for D in $@; do
    local U=$(echo "$LSBLK" | grep ${D#/dev/}'[[:space:]]' | awk '{ print $2 }')
    [ "$U" ] || U=$D
    UUIDS="$UUIDS $U"
  done

  echo -n "${UUIDS/ /}"
}


# --------------------------------------------------------------------------

# Prints to stdout a device name for each partition UUID that was passed as
# an argument. If no device can be located for a partition UUID then the
# UUID itself is printed.
#
# Arguments:
#   $1, $2, $3, ...  partition UUIDs (as generated by devs_to_parts)
#
parts_to_devs() {
  local P
  local DEVS=
  local LSBLK=$(lsblk -n -o NAME,PARTUUID -d /dev/sd[a-z]?* || true)

  for P in $@; do
    local D=$(echo "$LSBLK" | grep -E '(^| )'${P#/dev/}'($| )' | awk '{ printf "/dev/%s", $1 }')
    [ "$D" ] || D=$P
    DEVS="$DEVS $D"
  done

  echo -n "${DEVS/ /}"
}


# --------------------------------------------------------------------------

# Prints the UUID that corresponds to the specified block device to stdout.
# The block device may one of /dev/mapper/*.
#
# Arguments:
#   $1  block device
#
dev_to_uuid() {
  if [ "$1" ]; then
    local UUID=$(blkid -p -o value -s UUID "$1" 2>/dev/null)
    # Must not read superblocks to get UUID of /dev/mapper/*
    [ "$UUID" ] || UUID=$(blkid -o value -s UUID "$1" 2>/dev/null)
    echo -n "$UUID"
  fi
}


# --------------------------------------------------------------------------

# In a list of block devices, tries to replace each device by the matching
# /dev/disk/by-uuid device. If there is no UUID or if the device is one of
# /dev/mapper/* then it is not replaced.
# Prints the resulting list to stdout.
#
# Arguments:
#   $1, $2, $3, ...  block devices (/dev/*, ...)
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

  echo -n ${REPLACED_DEVS/ /}
}


# --------------------------------------------------------------------------

# Returns status 0 iff the specified block device is an SSD.
#
# Arguments:
#   $1  block device
#
is_ssd() {
  [ "$(lsblk -dnro RM,ROTA $1 2>/dev/null || true)" = '0 0' ]
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
  local DIR_NAME
  local MP

  DIR_NAME=$(readlink -e $(dirname $1)) || return
  MP=$(stat --printf '%m' $DIR_NAME) || return
  echo -n "${DIR_NAME#$MP}/$(basename $1)"
}


# --------------------------------------------------------------------------

# Translates device names from $STORAGE_DEVS and $CACHED_BY to partition
# UUIDs that remain valid even if the system is rebooted with a different
# device naming scheme or if file systems or RAID components are wiped.
# Saves the partition UUIDs in variables STORAGE_PART_UUIDS and
# CACHE_PART_UUIDS in $CONFIG_FILE.
#
# Arguments:
#   $STORAGE_DEVS  array of storage device names
#   $CACHED_BY     array of space-delimited lists of cache device names
# Results:
#   CONFIG_FILE    updated
# Calls:
#   devs_to_parts
#
save_parts() {
  local -a STORAGE_PART_UUIDS
  local -a CACHE_PART_UUIDS
  local I

  for I in ${!STORAGE_DEVS[@]}; do
    STORAGE_PART_UUIDS[$I]=$(devs_to_parts ${STORAGE_DEVS[$I]})
  done

  for I in ${!CACHED_BY[@]}; do
    CACHE_PART_UUIDS[$I]=$(devs_to_parts ${CACHED_BY[$I]})
  done

  echo "$(declare -p STORAGE_PART_UUIDS)" >> "$CONFIG_FILE"
  echo "$(declare -p CACHE_PART_UUIDS)" >> "$CONFIG_FILE"
}


# --------------------------------------------------------------------------

# Translates partition UUIDs from $STORAGE_PART_UUIDS and $CACHE_PART_UUIDS
# to device names in STORAGE_DEVS and CACHED_BY.
# 
# Arguments:
#   $STORAGE_PART_UUIDS  array of storage partition UUIDs
#   $CACHE_PART_UUIDS    array of space-delimited lists of cache partition
#                        UUIDs
# Results:
#   STORAGE_DEVS         array of storage device names
#   CACHED_BY            array of space-delimited lists of cache device names
# Calls:
#   parts_to_devs
#
load_parts() {
  declare -g -a STORAGE_DEVS  # if not already defined
  declare -g -a CACHED_BY
  local I

  for I in ${!STORAGE_PART_UUIDS[@]}; do
    STORAGE_DEVS[$I]=$(parts_to_devs ${STORAGE_PART_UUIDS[$I]})
  done

  for I in ${!CACHE_PART_UUIDS[@]}; do
    CACHED_BY[$I]=$(parts_to_devs ${CACHE_PART_UUIDS[$I]})
  done
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
  local MSG="--- Waiting for $1 $2 "
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

# Creates or assembles an MD/RAID and saves the name of the resulting
# RAID device to a variable.
#
# Arguments:
#   $1                space-delimited list of devices (RAID components)
#   $2                RAID level (1, 4, 5, 6 or 10)
#   $3                label, becomes part of the resulting RAID device path
#   $PREFIX           prepended to the label in the device path
#   $TARGET_HOSTNAME  used as RAID hostname
#   $BUILD_GOAL       non-empty if building a new storage
#   $MOUNT_GOAL       non-empty if mounting a storage
# Results:
#   MD_DEV            name of the created/asembled RAID device
# Calls:
#   require_pkg, new_path, num_words, is_ssd, wait_file
#   $HERE/${SCRIPT_NAME}.mdraid-helper
#
prepare_raid() {
  require_pkg -t mdadm smartmontools

  declare -g MD_DEV=$(new_path /dev/md/${PREFIX}$3)
  local NUM_DEVS=$(num_words $1)

  if [ "$BUILD_GOAL" ]; then
    info "Creating RAID $MD_DEV on homehost $TARGET_HOSTNAME from components ${1// /, }"

    # Mixed SSD/HDD array?
    local SSD_DEVS=
    local HDD_DEVS=

    for D in $1; do
      if is_ssd $D; then
        SSD_DEVS="$SSD_DEVS $D"
      else
        HDD_DEVS="$HDD_DEVS $D"
      fi
    done

    SSD_DEVS=${SSD_DEVS/ /}
    HDD_DEVS=${HDD_DEVS/ /}

    wipefs -a $1
    if [ $2 -eq 1 -a -n "$SSD_DEVS" -a -n "$HDD_DEVS" ]; then
      # Mixed SSD/HDD RAID1 array, prefer reading from SSD
      info "Will prefer reading from ${SSD_DEVS// /, }, writing-behind to ${HDD_DEVS// /, }"
      yes | mdadm --quiet --create $MD_DEV --level=$2 \
        --homehost=$TARGET_HOSTNAME --raid-devices=$NUM_DEVS $SSD_DEVS \
        --write-behind --bitmap=internal --write-mostly $HDD_DEVS

    else
      # SSD-only/HDD-only array
      yes | mdadm --quiet --create $MD_DEV --level=$2 \
        --homehost=$TARGET_HOSTNAME --raid-devices=$NUM_DEVS $1
    fi
    echo ''

    # Wait until device actually available (can take some time while syncing)
    wait_file $MD_DEV

  elif [ "$MOUNT_GOAL" ]; then
    info "Assembling RAID $MD_DEV from components ${1// /, }"
    mdadm --quiet --assemble $MD_DEV $1
  fi

  # Adjust drive/driver error timeouts on host
  . "$HERE/${SCRIPT_NAME}.mdraid-helper" $MD_DEV
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
    FSTAB="${FSTAB}"$'\n'"# Device was $1 at installation:"
    local DEV="UUID=$UUID"
  else
    local DEV=$1
  fi

  local OPTIONS=${4:-defaults}

  FSTAB="${FSTAB}"$'\n'"$DEV	$2	$3	$OPTIONS	0	$5"
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
#   devs_to_disks_by_uuid, is_ssd, contains_word
#

# /etc/crypttab is being built here
CRYPTTAB='# <target name>		<source device>		<key file>		<options>'

format_luks() {
  # Format LUKS device
  keyctl pipe $KEY_ID | cryptsetup --batch-mode --hash sha512 --key-size 512 --key-file - luksFormat $1

  # Change LUKS authorization method from 1 to 0 for the first occurrence
  # This prompts for a passphrase in $KEY_SCRIPT and does not save an invalid
  # passphrase to the keyring
  local ACTUAL_AUTH_METHOD=$AUTH_METHOD
  [ "$AUTH_METHOD" = 1 ] && ! contains_word "0:$MP_REL_KEY_FILE" "$CRYPTTAB" && ACTUAL_AUTH_METHOD=0

  # Add CRYPTTAB entry
  CRYPTTAB="$CRYPTTAB"$'\n'"$2 $(devs_to_disks_by_uuid $1) $ACTUAL_AUTH_METHOD:$MP_REL_KEY_FILE luks,initramfs,keyscript=$KEY_SCRIPT,noauto"

  # Add a 'discard' option for SSDs
  if is_ssd $1; then
    CRYPTTAB="$CRYPTTAB,discard"
  fi
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
  info "Mounting devices for chroot-ing into $TARGET"
  for D in /dev /dev/pts /proc /run /sys; do
    mkdir -p ${TARGET}${D}
    mount --bind $D ${TARGET}${D}
  done

  sleep 3   # wait until everything has settled
}


# --------------------------------------------------------------------------

# Writes the file system configuration files to the target system.
#
# Arguments:
#   variables defined in $CONFIG_FILE
#   many more...
# Calls:
#   initramfs_hook
#
write_config_files() {
  # Create /etc/fstab
  mkdir -p $TARGET/etc
  echo "$FSTAB" > $TARGET/etc/fstab

  # Boot-time decryption
  if [[ ! "${ENCRYPTED[*]}" =~ $BLANK_RE ]]; then
    # Copy keyscript to initramfs
    mkdir -p ${TARGET}$(dirname $KEY_SCRIPT)
    cp -f "$HERE/${SCRIPT_NAME}.keyscript" ${TARGET}$KEY_SCRIPT
    chmod 700 ${TARGET}$KEY_SCRIPT
    initramfs_hook crypt -c $KEY_SCRIPT -x $(which keyctl) -x $(which gpg)

    # Create /etc/crypttab using keyscript authentication
    mkdir -p $TARGET/etc
    echo "$CRYPTTAB" > $TARGET/etc/crypttab
  fi

  # udev rule for RAID arrays
  if [[ ! "${RAID_LEVELS[*]}" =~ $BLANK_RE ]]; then
    # Add udev rule to adjust drive/driver error timeouts
    mkdir -p ${TARGET}$(dirname $RAID_RULE_FILE)
    cp -f "$HERE/${SCRIPT_NAME}.mdraid-rule" ${TARGET}$RAID_RULE_FILE
    chmod 644 ${TARGET}$RAID_RULE_FILE

    # Copy udev helper script to initramfs
    mkdir -p ${TARGET}$(dirname $RAID_HELPER_FILE)
    cp -f "$HERE/${SCRIPT_NAME}.mdraid-helper" ${TARGET}$RAID_HELPER_FILE
    chmod 755 ${TARGET}$RAID_HELPER_FILE

    initramfs_hook mdraid-helper -c $RAID_RULE_FILE -c $RAID_HELPER_FILE -x $(which smartctl)
  fi

  # Standard bcache udev rule seems to fail sometimes for RAIDs, therefore ...
  if [[ ! "${RAID_LEVELS[*]}" =~ $BLANK_RE ]] && [[ ! "${CACHED_BY[*]}" =~ $BLANK_RE ]]; then
    # Override default udev rule with custom rule
    local BCACHE_RULE_FILE=/etc/udev/rules.d/$(find /lib/udev/rules.d/ -name '*-bcache.rules' -type f -printf '%P')
    mkdir -p ${TARGET}$(dirname $BCACHE_RULE_FILE)
    cp -f "$HERE/${SCRIPT_NAME}.bcache-rule" ${TARGET}$BCACHE_RULE_FILE
    chmod 644 ${TARGET}$BCACHE_RULE_FILE

    # Copy udev helper script to initramfs
    mkdir -p ${TARGET}$(dirname $BCACHE_HELPER_FILE)
    cp -f "$HERE/${SCRIPT_NAME}.bcache-helper" ${TARGET}$BCACHE_HELPER_FILE
    chmod 755 ${TARGET}$BCACHE_HELPER_FILE
    echo "$BCACHE_HINTS" > ${TARGET}$BCACHE_HINT_FILE
    chmod 644 ${TARGET}$BCACHE_HINT_FILE

    initramfs_hook bcache-helper -c $BCACHE_RULE_FILE -c $BCACHE_HELPER_FILE -c $BCACHE_HINT_FILE -x $(which bcache-super-show)
  fi

  # Copy test script
  local TARGET_TEST_SCRIPT=/usr/local/sbin/${SCRIPT_NAME}-test.sh
  mkdir -p ${TARGET}$(dirname $TARGET_TEST_SCRIPT)
  cp -f "$TEST_SCRIPT" ${TARGET}$TARGET_TEST_SCRIPT
  chmod 755 ${TARGET}$TARGET_TEST_SCRIPT
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

Optionally, a basic bootable $DISTRIB_DESCRIPTION can be installed,
or an existing system.

Usage: $SCRIPT [-b|-m] [-i|-c] [-y] [-d] [<config-file>]
       $SCRIPT -u [-y] [<config-file>]
       $SCRIPT -h

  <config-file> describes the target storage and can be created and
  edited interactively prior to any other action. If no <config-file>
  is specified then $DEFAULT_CONFIG_FILE is used by default.

  Options:
    -b  (Re-)Builds the target storage and mounts it at the mount
        point specified in <config-file>. Host devices required for
        chrooting are also mounted. Existing data on the underlying
        block devices will be overwritten.
    -i  Installs a basic bootable $DISTRIB_DESCRIPTION onto the
        target storage, with the same architecture as the host system.
    -c  Clones an existing $DISTRIB_DESCRIPTION system from a
        mount point which may be local or on a remote host.
        Such a remote host must be an rsync server, and the remote
        source must be given in a form recognizable by rsync.
        The source system should *not* be running and should also be
        an $DISTRIB_DESCRIPTION system.
    -m  (Re-)Mounts a previously built target storage at the mount
        point specified in <config-file>. Host devices required for
        chrooting are also mounted. See -u for unmounting.
    -u  Unmounts everything from the target storage mount point and
        stops encryption, caching and RAIDs on the underlying devices.
    -y  Batch mode: accepts default responses automatically, fails if
        any input beyond that is required. Use with caution.
    -d  Debug mode: pauses the script at various stages and makes the
        target system boot verbosely. Repeating this option increases
        the debugging level.
    -h  Displays this text and exits.

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
#   dev_dirs, _unlock_devs
#
cleanup() {
  set +e

  # Unmount everything from $TARGET if it is a directory
  if [ -d "$TARGET" ]; then
    for MP in $(cat /proc/mounts | grep "$TARGET"'[ /]' | cut -d ' ' -f 2 | sort -r); do
      info "Unmounting $MP"
      umount -l $MP
      sleep 0.5
    done
  fi

  # Unlock devices recursively
  _unlock_devs $@

  set -e
}

_unlock_devs() {
  local D
  local DEV
  local MP
  local BC_DIR

  for D in $@; do
    dev_dirs /dev/$D
    BC_DIR=$BCACHE_DIR

    # Unlock any holders; these include cache sets for backing devices
    [ "$(/bin/ls -A $HOLDERS_DIR)" ] && _unlock_devs $(basename -a $HOLDERS_DIR/*)

    # Get device path
    case $D in
      dm-[1-9]*)
        DEV=/dev/mapper/$(cat /sys/block/$D/dm/name)
        ;;
      *)
        DEV=/dev/$D
        ;;
    esac
    
    # If the device is a cache device then detach all backing devices
    # and close this device
    if [ -f $BC_DIR/set/unregister ]; then
      info "Unregistering cache $DEV"
      echo 1 > $BC_DIR/set/unregister
    fi

    # Turn off swapping if the device is swap space
    swapoff $DEV 2>/dev/null || true

    # Unlock device
    case $D in
      md[1-9]*)
        echo -n "--- Stopping RAID $DEV .."
        sleep 0.5
        while true; do
          echo -n '.'
          # Will fail as long as the array is still being sync'ed
          mdadm --wait-clean $DEV && mdadm --stop $DEV 1>&2 2>/dev/null && break
          sleep 1
          # Can stop syncing only for a short time, will restart automatically soon
          echo idle >/sys/block/$D/md/sync_action 2>/dev/null
        done
        sleep 0.5
        echo ''
        ;;

      bcache[0-9]*)
        BACKING_DEV=/dev/
        info "Stopping cache $DEV"
        sleep 0.5
        echo 1 >$BC_DIR/detach
        echo 1 >$BC_DIR/stop
        sleep 0.5
        ;;

      dm-[0-9]*)
        info "Closing mapped LUKS device $DEV"
        sleep 0.5
        cryptsetup luksClose $DEV
        sleep 0.5
        ;;

      sd*)
        if [ -e $BC_DIR/set/stop ]; then
          info "Stopping cache device $DEV"
          sleep 0.5
          echo 1 >$BC_DIR/set/stop
          sleep 0.5
        fi
        ;;
      *)
        echo "*** Do not know how to stop $D ***" 1>&2
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
CLONE_SRC=

while getopts hbmicydu OPT; do
  case "$OPT" in
    h|b|m|i|c|u)
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
CLONE_GOAL=
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
    FRIENDLY_GOAL="build and install $DISTRIB_DESCRIPTION to"
    ;;
  'b c')
    BUILD_GOAL=1
    CLONE_GOAL=1
    FRIENDLY_GOAL="build and clone to"
    ;;
  m)
    MOUNT_GOAL=1
    FRIENDLY_GOAL='mount'
    ;;
  'i m')
    MOUNT_GOAL=1
    INSTALL_GOAL=1
    FRIENDLY_GOAL="mount and install $DISTRIB_DESCRIPTION to"
    ;;
  'c m')
    MOUNT_GOAL=1
    CLONE_GOAL=1
    FRIENDLY_GOAL="mount and clone to"
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

# Abort on error
set -e

# Configuration variables
declare -a STORAGE_DEVS=()
declare -a STORAGE_PART_UUIDS=()
declare -a RAID_LEVELS=()
declare -a CACHED_BY=()
declare -a CACHE_PART_UUIDS=()
declare -a CACHE_RAID_LEVELS=()
declare -a BUCKET_SIZES=()
declare -a ENCRYPTED=()
declare -a FS_TYPES=()
declare -a MOUNT_POINTS=()
declare -a MOUNT_OPTIONS=()

TARGET=
AUTH_METHOD=
KEY_FILE=
KEY_FILE_SIZE=
PREFIX=
TARGET_HOSTNAME=$HOSTNAME
TARGET_USERNAME=
TARGET_PWHASH=
SRC_HOSTNAME=
SRC_PORT=22
SRC_USERNAME=
SRC_DIR=
SRC_EXCLUDES=

# Repeat configuration until confirmed by user
while true; do

  # ---------------------- Collect configuration info ------------------------

  if [ -z "$SKIP_CONFIG_FILE" -a -f "$CONFIG_FILE" ]; then
    # Read previous configuration
    . "$CONFIG_FILE"

    # Translate identifiers to device names
    load_parts

  else
    if [ -z "$BATCH_MODE" ]; then
      # Show overview of devices and partitions
      cat <<- EOF

Block devices
=============
  
EOF
      lsblk -o NAME,FSTYPE,SIZE,LABEL,MOUNTPOINT /dev/sd? || true
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
      STORAGE_PART_UUIDS[$NUM_FS]=
      HINT=', empty to continue'
      VOL_HINT='additional '

      # Request RAID level if enough devices specified
      RAID_LEVEL=$(raid_levels_for $DEVS)
      if [ "$RAID_LEVEL" ]; then
        RAID_LEVELS[$NUM_FS]=$(read_text '  RAID level: ' "${RAID_LEVELS[$NUM_FS]}" "$RAID_LEVEL")
      else
        RAID_LEVELS[$NUM_FS]=
      fi

      # Optional SSD cache devices (must always be in the same order)
      DEVS=$(read_devs '  Cache partition(s) (optional, two or more make a RAID): ' "${CACHED_BY[$NUM_FS]}" multiple optional)
      CACHED_BY[$NUM_FS]=$(sorted_unique $DEVS)
      CACHE_PART_UUIDS[$NUM_FS]=

      if [ "$DEVS" ]; then
        # Request cache RAID level if enough devices specified
        RAID_LEVEL=$(raid_levels_for $DEVS)
        if [ "$RAID_LEVEL" ]; then
          CACHE_RAID_LEVELS[$NUM_FS]=$(read_text '  RAID level: ' "${CACHE_RAID_LEVELS[$NUM_FS]}" "$RAID_LEVEL")
        else
          CACHE_RAID_LEVELS[$NUM_FS]=
        fi

        # Cache bucket size (SSD erase block size unless it uses TLC)
        while true; do
          BUCKET_SIZES[$NUM_FS]=$(read_int "    Bucket size (64k...64M): " "${BUCKET_SIZES[$NUM_FS]}" 64k 64M)
          VALUE=$(to_int ${BUCKET_SIZES[$NUM_FS]})
          [ $VALUE -gt 0 -a $(( $VALUE & ($VALUE-1) )) -eq 0 ] && break
          echo '*** Value must be a power of 2 ***' 1>&2
        done

      else
        # No chache
        CACHE_RAID_LEVELS[$NUM_FS]=
      fi

      # Optional LUKS encryption
      [ "${ENCRYPTED[$NUM_FS]}" ] && DEFAULT=y || DEFAULT=n
      confirmed '  LUKS-encrypted' $DEFAULT && ENCRYPTED[$NUM_FS]=y || ENCRYPTED[$NUM_FS]=

      # File system type
      FS_TYPE=$(read_text '  File system: ' "${FS_TYPES[$NUM_FS]}" "$(sorted_unique ${!DEFAULT_MOUNT_OPTION_MAP[@]})")
      [ "$FS_TYPE" != "${FS_TYPES[$NUM_FS]}" ] && MOUNT_OPTIONS[$NUM_FS]=${DEFAULT_MOUNT_OPTION_MAP[$FS_TYPE]}
      FS_TYPES[$NUM_FS]=$FS_TYPE

      # Mount points
      DEFAULT="${MOUNT_POINTS[$NUM_FS]}"
      [ -z "$DEFAULT" -a $NUM_FS -eq 0 ] && DEFAULT=/
      case "${FS_TYPES[$NUM_FS]}" in
        btrfs)
          # Each mount point becomes a subvolume
          MOUNT_POINTS[$NUM_FS]=$(read_dirpaths '    Mount points (become top-level subvolumes with leading '@'): ' "$DEFAULT" multiple verify)
          ;;
        swap)
          # No mount point
          MOUNT_POINTS[$NUM_FS]=
          ;;
        *)
          # Single mount point
          MOUNT_POINTS[$NUM_FS]=$(read_dirpaths '    Mount point: ' "$DEFAULT" '' verify)
          ;;
      esac

      # Mount options
      if [ "$FS_TYPE" != swap ]; then
        DEFAULT=${MOUNT_OPTIONS[$NUM_FS]}
        [ "$DEFAULT" ] || DEFAULT=${DEFAULT_MOUNT_OPTION_MAP[$FS_TYPE]}
        MOUNT_OPTIONS[$NUM_FS]=$(read_text '    Mount options (optional): ' "$DEFAULT" '.*')
      fi
    done

    # Remove unused configuration entries
    for (( I=${#STORAGE_DEVS[@]}-1; I>=$NUM_FS; I-- )); do
      unset STORAGE_DEVS[$I]
      unset STORAGE_PART_UUIDS[$I]
      unset RAID_LEVELS[$I]
      unset CACHED_BY[$I]
      unset CACHE_PART_UUIDS[$I]
      unset CACHE_RAID_LEVELS[$I]
      unset ENCRYPTED[$I]
      unset FS_TYPES[$I]
      unset MOUNT_POINTS[$I]
      unset MOUNT_OPTIONS[$I]
    done

    # Authorization is required if any file system is encrypted
    if [[ "${ENCRYPTED[@]}" =~ $BLANK_RE ]]; then
      AUTH_METHOD=
      KEY_FILE=
      KEY_FILE_SIZE=

    else
      require_pkg gnupg keyutils

      PREV_AUTH_METHOD=$AUTH_METHOD
      AUTH_METHOD=$(read_text $'LUKS authorization method\n  1=passphrase\n  2=key file (may be on a LUKS partition)\n  3=encrypted key file: ' "$AUTH_METHOD" '1 2 3')

      KEY_ID=
      PW_ID=

      case $AUTH_METHOD in
        1)
          # Save passphrase to keyring, use passphrase as LUKS key
          KEY_ID=$(read_passphrase 'LUKS passphrase' "$BUILD_GOAL")
          KEY_FILE=
          KEY_FILE_SIZE=
          MP_REL_KEY_FILE=
          ;;

        2)
          # Select key file, create it if $BUILD_GOAL and not found
          while true; do
            KEY_FILE=$(read_filepath '  Key file (preferably on a removable device): ' "$KEY_FILE")

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
              KEY_FILE_SIZE=$(to_int $(read_int '    size (256...8192 bytes): ' "$KEY_FILE_SIZE" 256 8k))
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
            KEY_FILE=$(read_filepath '  Encrypted key file (preferably on a removable device): ' "$KEY_FILE")

            if ! MP_REL_KEY_FILE=$(mount_point_relative "$KEY_FILE"); then
              # Directory does not exist
              echo "*** Directory does not exist: $(dirname $KEY_FILE) ***" 1>&2
              continue

            elif [ -r "$KEY_FILE" ]; then
              # Key file exists, get passphrase and verify that the file can be decrypted
              while true; do
                PW_ID=$(read_passphrase 'Key file passphrase')
                cat "$KEY_FILE" | gpg --quiet --yes --passphrase $(keyctl pipe $PW_ID) --output /dev/null && break 2
              done

            elif [ -e "$KEY_FILE" -o -z "$BUILD_GOAL" ]; then
              # Something else exists, or we are not building the target file system
              echo "*** Not a readable file: $KEY_FILE ***" 1>&2
              continue

            else
              # Building the target file system, and key file does not exist -- create it
              confirmed "  $KEY_FILE does not exist, create it" || continue
              KEY_FILE_SIZE=$(to_int $(read_int '  size (256...8192 bytes): ' "$KEY_FILE_SIZE" 256 8k))

              # Get passphrase
              PW_ID=$(read_passphrase 'Key file passphrase' verify)

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
    PREFIX=$(read_text 'Prefix to mapper names and labels (recommended): ' "$PREFIX" '[A-Za-z0-9_-]*')
    
    # Target mount point
    while true; do
      TARGET=$(read_filepath 'Target mount point: ' "$TARGET")
      [ -d "$TARGET" ] && break
      confirmed "  $TARGET does not exist, create it" y && break
    done

    # Target system's hostname, username and password
    if [ "$INSTALL_GOAL" ]; then
      TARGET_HOSTNAME=$(read_text 'Hostname: ' "$TARGET_HOSTNAME" '[A-Za-z][A-Za-z0-9_.-]*')

      PREV_USERNAME=$TARGET_USERNAME
      TARGET_USERNAME=$(read_text "Username (empty to copy host user '$SUDO_USER'): " "$TARGET_USERNAME" '([A-Za-z][A-Za-z0-9_-]*)?')

      if [ "$TARGET_USERNAME" ]; then
        # Read login passphrase, previous login passphrase may be reused if it exists and if the username was not changed
        [ "$TARGET_USERNAME" != "$PREV_USERNAME" ] && TARGET_PWHASH=
        TARGET_PWHASH=$(read_login "$TARGET_PWHASH")
      else
        # Copy current user and login passphrase
        TARGET_USERNAME=$SUDO_USER
        TARGET_PWHASH=$(grep $SUDO_USER /etc/shadow | cut --delimiter ':' --fields 2)
      fi
    fi

    # Source for cloning (hostname or IPv4 or IPv6 address)
    if [ "$CLONE_GOAL" ]; then
      SRC_HOSTNAME=$(read_text 'Remote host to clone from (empty for a local directory): ' "$SRC_HOSTNAME" '([A-Za-z][A-Za-z0-9_.-]*)|([0-9\.:]+)?')

      if [ "$SRC_HOSTNAME" ]; then
        # Remote source (verified later)
        SRC_PORT=$(to_int $(read_int '  Remote SSH port: ' "$SRC_PORT" 1 65535))
        SRC_USERNAME=$(read_text '  Remote username (required only if password authentication): ' "$SRC_USERNAME" '([A-Za-z][A-Za-z0-9_-]*)?')
        SRC_DIR=$(read_dirpaths '  Remote source directory: ' "$SRC_DIR")

      else
        # Local source
        SRC_PORT=
        SRC_USERNAME=
        SRC_DIR=$(read_dirpaths '  Source directory: ' "$SRC_DIR" '' verify)
      fi

      SRC_EXCLUDES=$(read_dirpaths '    Subpaths to exclude from copying (optional): ' "$SRC_EXCLUDES" multiple)
    fi
  fi

  # Boot file system is the root file system or the file system having mount point /boot
  BOOT_DEV_INDEX=0
  for (( I=1; I<NUM_FS; I++ )); do
    contains_word /boot ${MOUNT_POINTS[$I]} && BOOT_DEV_INDEX=$I && break
  done

  # Determine boot devices
  BOOT_DEVS="$(sorted_unique_disks ${STORAGE_DEVS[$BOOT_DEV_INDEX]})"
  
  # Collect RAIDs that are used as cache devices
  declare -A CACHE_RAID_LEVEL_MAP=()   # cache device(s) -> RAID level
  declare -A BUCKET_SIZE_MAP=()        # cache device(s) -> bucket size

  for I in ${!CACHE_RAID_LEVELS[@]}; do
    if [ "${CACHED_BY[$I]}" ]; then
      [ "${CACHE_RAID_LEVELS[$I]}" ] && CACHE_RAID_LEVEL_MAP[${CACHED_BY[$I]}]=${CACHE_RAID_LEVELS[$I]}
      BUCKET_SIZE_MAP[${CACHED_BY[$I]}]=${BUCKET_SIZES[$I]}
    fi
  done

  SKIP_CONFIG_FILE=1


  # ------------------------ Check the configuration -----------------------

  ERROR=
  WARNINGS=
  echo ''

  # Enough devices for each RAID level of storage and cache?
  for (( I=0; I<NUM_FS; I++ )); do
    RAID_LEVEL=$(raid_levels_for ${STORAGE_DEVS[$I]})
    [ ! "${STORAGE_DEVS[$I]}" ] || ! contains_word ${RAID_LEVELS[$I]} '' $RAID_LEVEL \
      && error "Too few storage devices for file system #$((I+1)) (${FS_TYPES[$I]} on ${MOUNT_POINTS[$I]})"

    RAID_LEVEL=$(raid_levels_for ${CACHED_BY[$I]})
    ! contains_word ${CACHE_RAID_LEVELS[$I]} '' $RAID_LEVEL \
      && error "Too few cache devices for file system #$((I+1)) (${FS_TYPES[$I]} on ${MOUNT_POINTS[$I]})"
  done  

  # Do all block devices exist?
  for D in $(sorted_unique ${STORAGE_DEVS[@]} ${CACHED_BY[@]}); do
    [ ! -b $D ] && error "Not a block device: $D"
  done

  # Any device assigned multiple times?
  CACHED_BY_DEVS=$(sorted_unique ${CACHED_BY[@]})
  DUPLICATE_DEVS=$(sorted_duplicates ${STORAGE_DEVS[@]} $CACHED_BY_DEVS)
  [ "$DUPLICATE_DEVS" ] && error "Partition(s) assigned multiple times: $DUPLICATE_DEVS"

  # Any cache device assigned multiple times?
  RAID_DUPLICATES=$(sorted_duplicates ${!CACHE_RAID_LEVEL_MAP[@]})
  [ "$RAID_DUPLICATES" ] && error "Cache partition(s) assigned multiple times: $RAID_DUPLICATES"

  # Warn if any cache device is removable or rotational
  for D in $CACHED_BY_DEVS; do
    ! is_ssd $D && warning "Cache partition $D is not on an SSD -- are you sure?"
  done

  # Root file system must not be a swap FS
  [ "${FS_TYPES[0]}" = 'swap' ] \
    && error "Root file system must not be a ${FS_TYPES[0]} file system"

  # Swap file systems cannot be cached
  for (( I=0; I<NUM_FS; I++ )); do
    [ "${FS_TYPES[$I]}" = 'swap' -a -n "${CACHED_BY[$I]}" ] \
      && error "A ${FS_TYPES[$I]} file system cannot be cached: ${STORAGE_DEVS[$I]}"
  done
 
  # Warn if there are multiple swap file systems
  [[ $(sorted_duplicates ${FS_TYPES[@]}) == *swap* ]] \
    && warning "Hibernation may not work with multiple swap partitions. RAID0 could be an alternative."

  # Root mount point for root file system?
  MP=$(sorted_unique ${MOUNT_POINTS[0]})
  [ "${MP%% *}" != / ] && error "Root file system not at mount point /"

  # Do the mount points exist as directories?
  for D in $MP; do
    [ ! -d $D ] && error "Mount point not found on host system: $D"
  done

  # Any duplicate mount points?
  MP_DUP=$(sorted_duplicates ${MOUNT_POINTS[@]})
  [ "$MP_DUP" ] && error "Mount points assigned multiple times: $MP_DUP"

  # Key file must be readable unless we are unmounting
  if [ -z "$UNMOUNT_GOAL" ]; then
    [ -n "$KEY_FILE" -a ! -r "$KEY_FILE" ] && error "Not a readable file: $KEY_FILE"
  fi

  if [ "${INSTALL_GOAL}${CLONE_GOAL}" ]; then
    # Attempting to cache the boot file system?
    [ "${CACHED_BY[$BOOT_DEV_INDEX]}" ] \
      && error "The /boot file system must not be cached: ${STORAGE_DEVS[$BOOT_DEV_INDEX]}"

    # Encrypted boot partition must be using a passphrase (GRUB does not support key files)
    [ -n "${ENCRYPTED[$BOOT_DEV_INDEX]}" -a -n "$AUTH_METHOD" ] && [ $AUTH_METHOD -gt 1 ] \
      && error "The /boot file system must not be encrypted using a key file: ${STORAGE_DEVS[$BOOT_DEV_INDEX]}"
  fi

  if [ "$INSTALL_GOAL" ]; then
    # Username (and password) specified?
    [ ! "$TARGET_USERNAME" ] && error '*** Target username is missing ***'
    
    # We will need the host's package repository
    REPO=$(grep -m 1 -o -E 'https?://.*(archive\.ubuntu\.com/ubuntu/|releases\.ubuntu\.com/)' /etc/apt/sources.list) \
      || die 'No Ubuntu repository URL found in /etc/apt/sources.list'
  fi

  if [ "$CLONE_GOAL" ]; then
    # Cloning from a remote host?
    if [ "$SRC_HOSTNAME" ]; then
      require_pkg openssh-client

      # Options for SSH master connection
      # Everything would be *much* easier if CONFIG_FILE could not contain spaces...
      SSH_SOCKET="${CONFIG_FILE}:${SRC_HOSTNAME}:${SRC_PORT}:${SRC_USERNAME}"
      SSH_OPTS="-o ControlMaster=auto -o ControlPersist=$PW_EXPIRATION"
      [ "$SRC_PORT" ] && SSH_OPTS="$SSH_OPTS -p $SRC_PORT"
      [ "$SRC_USERNAME" ] && SSH_OPTS="$SSH_OPTS -l $SRC_USERNAME"

      # Prepare to close a new master connection on exit
      CLEANUP_SSH=
      ssh -S "$SSH_SOCKET" -O check $SRC_HOSTNAME 2>/dev/null || CLEANUP_SSH=1

      # Establish or re-use the master connection and check for the remote directory
      STATUS=0
      SRC_PREAMBLE='ssh -S'
      $SRC_PREAMBLE "$SSH_SOCKET" $SSH_OPTS $SRC_HOSTNAME [ -d "$SRC_DIR" ] || STATUS=$?
      
      if [ $STATUS -gt 1 ]; then
        # Master connection not established
        error "Unable to connect to '$SRC_HOSTNAME'"

      else
        # If the master connection was just established then close it on exit
        [ "$CLEANUP_SSH" ] && on_exit "Terminating SSH connection: $SSH_SOCKET" \
          "ssh -S '$SSH_SOCKET' -O exit $SRC_HOSTNAME 2>/dev/null"

        # Remote directory must exist
        [ $STATUS -eq 1 ] && error "Remote source directory '$SRC_DIR' not found"
      fi

    else
      # Local directory must exist
      [ ! -d "$SRC_DIR" ] && error "Source directory '$SRC_DIR' not found"

      STATUS=0
      SSH_SOCKET=
      SRC_PREAMBLE=eval
    fi

    # Verify that a physical device is mounted at SRC_DIR
    if [ $STATUS -eq 0 ] && ! $SRC_PREAMBLE "$SSH_SOCKET" $SRC_HOSTNAME \
      "findmnt -n -l -o TARGET,SOURCE -R $SRC_DIR | grep -q -E $SRC_DIR'[[:space:]]+/dev/'"; then
      error "No device mounted at source directory '$SRC_DIR'"
    fi
  fi

  if [ "$ERROR" ]; then
    if [ "$BATCH_MODE" ]; then
      die 'Invalid configuration'
    else
      read -rp $'\nInvalid configuration, [Enter] to edit: '
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

    lsblk -o NAME,FSTYPE,SIZE,LABEL $ALL_DISKS | grep -E "NAME${ALL_DISKS//\/dev\//|^}${ALL_DEVS//\/dev\//|}" || true
    echo ''

    VOL_HINT="Root file system:       "

    for (( I=0; I<NUM_FS; I++ )); do
      echo \
        "${VOL_HINT}${STORAGE_DEVS[$I]}"
      [ -n "$INSTALL_GOAL" -a "$I" = "$BOOT_DEV_INDEX" ] && echo \
        "  Boot device"
      [ "${RAID_LEVELS[$I]}" ] && echo \
        "  RAID level:           ${RAID_LEVELS[$I]}"

      if [ "${CACHED_BY[$I]}" ]; then
        echo \
        "  Cache partitions:     ${CACHED_BY[$I]}"
        [ "${CACHE_RAID_LEVEL_MAP[${CACHED_BY[$I]}]}" ] && echo \
        "    Cache RAID level:   ${CACHE_RAID_LEVEL_MAP[${CACHED_BY[$I]}]}"
        echo \
        "    Bucket size:        ${BUCKET_SIZE_MAP[${CACHED_BY[$I]}]}"
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
      [ "$MP_REL_KEY_FILE" ] && echo \
        "  Mount-point relative: $MP_REL_KEY_FILE"
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
      echo \
        "Username:               $TARGET_USERNAME"
    fi

    if [ "$CLONE_GOAL" ]; then
      echo \
        "Cloning from:           $SRC_DIR"
      [ "$SRC_EXCLUDES" ] && echo \
        "  excluded paths:       $SRC_EXCLUDES"
      [ "$SRC_HOSTNAME" ] && echo \
        "  on remote host:       $SRC_HOSTNAME:$SRC_PORT"
      [ "$SRC_USERNAME" ] && echo \
        "  user:                 $SRC_USERNAME"
    fi

    # Print warnings, if any
    [ "$WARNINGS" ] && echo "$WARNINGS"
    echo ''

    if [ "${BUILD_GOAL}${INSTALL_GOAL}${CLONE_GOAL}" ]; then
      echo "*** WARNING: existing data on ${ALL_DEVS// /, } will be overwritten! ***"$'\n'
      [ "${INSTALL_GOAL}${CLONE_GOAL}" ] && echo "*** WARNING: MBR on ${BOOT_DEVS// /, } will be overwritten! ***"$'\n'
    fi
    confirmed "About to $FRIENDLY_GOAL this configuration -- proceed" "$BATCH_MODE" || continue
  fi

  # Save configuration
  [ ! -f "$CONFIG_FILE" ] && info "Creating configuration file '$CONFIG_FILE'"
  sudo --user=$SUDO_USER truncate -s 0 "$CONFIG_FILE"
  echo \
"# StorageComposer configuration file, DO NOT EDIT
# created by $(readlink -e $0), $(date --rfc-3339 seconds)" >> "$CONFIG_FILE"

  for V in TARGET NUM_FS \
      STORAGE_DEVS RAID_LEVELS CACHED_BY CACHE_RAID_LEVELS BUCKET_SIZES \
      ENCRYPTED FS_TYPES MOUNT_POINTS MOUNT_OPTIONS \
      AUTH_METHOD KEY_FILE KEY_FILE_SIZE PREFIX \
      TARGET_HOSTNAME TARGET_USERNAME TARGET_PWHASH \
      SRC_HOSTNAME SRC_PORT SRC_USERNAME SRC_DIR SRC_EXCLUDES; do
    echo "$(declare -p $V)" >> "$CONFIG_FILE"
  done
  save_parts

  # For encryption, save the LUKS key to the keyring
  if [ "${BUILD_GOAL}${MOUNT_GOAL}" ]; then
    KEY_DESC="key:$CONFIG_FILE"

    case $AUTH_METHOD in
      1)
        # Save passphrase to keyring, passphrase == key
        [ "$KEY_ID" ] || KEY_ID=$(read_passphrase 'LUKS passphrase' "$BUILD_GOAL")
        ;;

      2)
        # Save key file content to keyring
        KEY_ID=$(cat "$KEY_FILE" | keyctl padd user "$KEY_DESC" @s)
        on_exit 'Revoking LUKS key' "keyctl revoke $KEY_ID"
        ;;

      3)
        # Save decrypted key file content to keyring
        while true; do
          [ "$PW_ID" ] || PW_ID=$(read_passphrase 'Key file passphrase')
          KEY_ID=$(cat "$KEY_FILE" | gpg --quiet --yes --passphrase "$(keyctl pipe $PW_ID)" --output - | keyctl padd user "$KEY_DESC" @s 2>/dev/null) && break
          PW_ID=
        done
        
        on_exit 'Revoking LUKS key' "keyctl revoke $KEY_ID"
        ;;
    esac
  fi

  break
done

# Disable udev rules (bcache rule interferes with setup)
info "Disabling 'other' udev rules"
udevadm control --property=DM_UDEV_DISABLE_OTHER_RULES_FLAG=1
on_exit "Re-enabling 'other' udev rules" 'udevadm control --property=DM_UDEV_DISABLE_OTHER_RULES_FLAG='

# Before building/mounting: stop encryption, caches and RAIDs in reverse order
DEVS_TO_UNLOCK=
for (( I=${#STORAGE_DEVS[@]}-1; I>=0; I-- )); do
  DEVS_TO_UNLOCK="$DEVS_TO_UNLOCK ${STORAGE_DEVS[$I]}"
done

DEVS_TO_UNLOCK="$DEVS_TO_UNLOCK $(sorted_unique ${CACHED_BY[@]})"
DEVS_TO_UNLOCK=${DEVS_TO_UNLOCK//\/dev\//}

# Clean up on error
trap "cleanup $DEVS_TO_UNLOCK" ERR

cleanup $DEVS_TO_UNLOCK
[ -d $TARGET ] && [ -n "$(ls -A $TARGET)" ] && die "$TARGET is not empty"

if [ "$UNMOUNT_GOAL" ]; then
  echo $'\n'"****** Storage unmounted from $TARGET ******"$'\n'
  exit
fi


# -------------------------- Create/assemble RAIDs -------------------------

declare -a LABELS
declare -a FS_DEVS
declare -A CACHE_DEVS_MAP  # single device -> itself, device list -> RAID device

for (( I=0; I<NUM_FS; I++ )); do
  # Sort mount points by increasing directory depth so that the root mount point is first, if present
  MOUNT_POINTS[$I]=$(sorted_unique ${MOUNT_POINTS[$I]})

  # Use the (first) mount point or the file system type as part of the RAID
  # name, of the bcache and LUKS /dev/mapper path and of the volume label
  MP_RE='^[[:space:]]*/([^[:space:]]*)'
  [[ "${MOUNT_POINTS[$I]}" =~ $MP_RE ]] && LABEL="${BASH_REMATCH[1]}" || LABEL=${FS_TYPES[$I]}
  LABEL=${LABEL//\//-}
  [ "$LABEL" ] || LABEL=root

  # Make the label unique within this configuration
  N=
  while contains_word ${LABEL}${N} ${LABELS[@]}; do
    N=$((N+1))
  done
  LABELS[$I]=${LABEL}${N}

  # Create/assemble storage RAIDs
  if [ "${RAID_LEVELS[$I]}" ]; then
    prepare_raid "${STORAGE_DEVS[$I]}" ${RAID_LEVELS[$I]} ${LABEL}
    FS_DEVS[$I]=$MD_DEV

    # Prevent RAIDs from being mistaken as SSDs by btrfs
    [ ${FS_TYPES[$I]} = btrfs ] && MOUNT_OPTIONS[$I]="nossd,${MOUNT_OPTIONS[$I]}"

  else
    FS_DEVS[$I]=${STORAGE_DEVS[$I]}
  fi

  # Cache required, and these cache devices not processed yet?
  DEVS=${CACHED_BY[$I]}
  if [ "$DEVS" ] && [ -z "${CACHE_DEVS_MAP[$DEVS]}" ]; then
    LEVEL=${CACHE_RAID_LEVEL_MAP[$DEVS]}
    if [ "$LEVEL" ]; then
      # Cache device is a RAID
      prepare_raid "$DEVS" $LEVEL cache-${LABEL}
      CACHE_DEVS_MAP[$DEVS]=$MD_DEV
    else
      # Cache device is a partition
      CACHE_DEVS_MAP[$DEVS]=$DEVS
    fi
  fi
done


# ----------------------- Cache and backing devices ------------------------

# Cache devices
declare -A CSET_UUIDS

for DEVS in "${!CACHE_DEVS_MAP[@]}"; do
  require_pkg -t bcache-tools
  modprobe bcache

  D=${CACHE_DEVS_MAP[$DEVS]}
  if [ "$BUILD_GOAL" ]; then
    info "Formatting $D as cache device"
    wipefs -a $D
    sleep 1
    CSET_RE='Set UUID:[[:space:]]*([^[:space:]]+)'
    [[ $(make-bcache -b ${BUCKET_SIZE_MAP[$DEVS]} -C $D) =~ $CSET_RE ]] || die "Unexepected output of make-bcache"

  elif [ "$MOUNT_GOAL" ]; then
    info "Registering $D as cache device"
    CSET_RE='cset.uuid[[:space:]]+([^[:space:]]+)'
    [[ $(bcache-super-show $D) =~ $CSET_RE ]] || die "Unexepected output of bcache-super-show"
  fi

  echo $D > /sys/fs/bcache/register 2>/dev/null || true
  CSET_UUIDS[$D]=${BASH_REMATCH[1]}
  wait_file /sys/fs/bcache/${CSET_UUIDS[$D]}
done

# Backing devices
declare -A CSET_FOR
declare -A BACKING_FOR

for (( I=0; I<NUM_FS; I++ )); do
  if [ "${CACHED_BY[$I]}" ]; then
    C=${CACHE_DEVS_MAP[${CACHED_BY[$I]}]}
    D=${FS_DEVS[$I]}
    CSET_UUID=${CSET_UUIDS[$C]}

    if [ "$BUILD_GOAL" ]; then
      info "Configuring $D as backing device"
      wipefs -a $D
      make-bcache -B $(readlink -e $D)
    fi

    CSET_FOR[$D]=$CSET_UUID
    BACKING_FOR[$CSET_UUID]="${BACKING_FOR[$CSET_UUID]} $D"

    info "Attaching $D to cache device $C"
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
  BCACHE_HINTS="$BCACHE_HINTS"$'\n'"$D=$C"
done

for C in ${!BACKING_FOR[@]}; do
  D=$(devs_to_disks_by_uuid ${BACKING_FOR[$C]})
  D=${D//\/dev\/disk\/by-uuid\//}
  C=backing_uuids_for_cset_${C//-/_}
  BCACHE_HINTS="$BCACHE_HINTS"$'\n'"$C='$D'"
done


# ------------------------------- Encryption -------------------------------

# LUKS encryption
for (( I=0; I<NUM_FS; I++ )); do
  if [ "${ENCRYPTED[$I]}" ]; then
    require_pkg -t cryptsetup gnupg keyutils

    # Avoid name conflicts with existing LUKS devices
    MAPPED_DEV=$(new_path /dev/mapper/${PREFIX}luks-${LABELS[$I]})
    MAPPED=${MAPPED_DEV#/dev/mapper/}
    LUKS_DEV=${FS_DEVS[$I]}
    info "Mapping LUKS device $LUKS_DEV to $MAPPED_DEV"
    [ "${BUILD_GOAL}${INSTALL_GOAL}${CLONE_GOAL}" ] && format_luks $LUKS_DEV $MAPPED
    keyctl pipe $KEY_ID | cryptsetup --key-file - luksOpen $LUKS_DEV $MAPPED
    FS_DEVS[$I]=$MAPPED_DEV
  fi
done


# ------------------------ (Re-)Create file systems ------------------------

if [ "${BUILD_GOAL}${INSTALL_GOAL}${CLONE_GOAL}" ]; then
  for (( I=0; I<NUM_FS; I++ )); do
    FS_DEV=${FS_DEVS[$I]}
    FS_TYPE=${FS_TYPES[$I]}
    LABEL=${LABELS[$I]}
    MP=(${MOUNT_POINTS[$I]})
    MO=${MOUNT_OPTIONS[$I]}

    info "Formatting $FS_DEV (volume ${PREFIX}${LABEL}) as $FS_TYPE"
    wipefs -a $FS_DEV
    
    case $FS_TYPE in
      ext[234]|xfs)
        [ $FS_TYPE = xfs ] && require_pkg -t xfsprogs
        mkfs.$FS_TYPE -L ${PREFIX}${LABEL} $FS_DEV
        sleep 1
        [ $MP = / ] && PASS=1 || PASS=2
        add_fstab $FS_DEV $MP $FS_TYPE "$MO" $PASS
        ;;

      btrfs)
        require_pkg -t btrfs-tools
        mkfs.btrfs -L ${PREFIX}${LABEL} -m dup $FS_DEV

        info "Creating subvolume(s) ${MP[@]/\//@} for $FS_DEV"
        TMP_MP=$(mktemp -d)
        on_exit "Removing temporary mount point: $TMP_MP", "rmdir $TMP_MP"
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
  for (( I=0; I<NUM_FS; I++ )); do
    if contains_word $MP ${MOUNT_POINTS[$I]}; then
      FS_DEV=${FS_DEVS[$I]}
      FS_TYPE=${FS_TYPES[$I]}
      MO=${MOUNT_OPTIONS[$I]}

      case $FS_TYPE in
        ext[234]|xfs)
          info "Mounting $FS_DEV at $TARGET$MP"
          mkdir -p $TARGET$MP
          mount -o "$MO" $FS_DEV $TARGET$MP
          ;;

        btrfs)
          # Mount subvolume
          info "Mounting $FS_DEV subvolume ${MP/\//@} at $TARGET$MP"
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


# Save UUIDs of devices having file a system for the test script
declare -a FS_DEVS_UUIDS=()
for I in ${!FS_DEVS[@]}; do
  FS_DEVS_UUIDS[$I]=$(dev_to_uuid ${FS_DEVS[$I]})
done
echo "$(declare -p FS_DEVS_UUIDS)" >> "$CONFIG_FILE"

# Create test script
TEST_SCRIPT="${CONFIG_FILE}-test.sh"
[ ! -f "$TEST_SCRIPT" ] && info "Creating test script '$TEST_SCRIPT'"
sudo --user=$SUDO_USER truncate -s 0 "$TEST_SCRIPT"
echo '#!/bin/bash' >> "$TEST_SCRIPT"
cat "$CONFIG_FILE" >> "$TEST_SCRIPT"
cat "$HERE/${SCRIPT_NAME}.fio" >> "$TEST_SCRIPT"
chmod 755 "$TEST_SCRIPT"

# Done if nothing to install or clone
if [ ! "${INSTALL_GOAL}${CLONE_GOAL}" ]; then
  # Can we chroot?
  if [ -f $TARGET/bin/bash ]; then
    CHROOT_MSG='and ready to chroot '
    mount_devs
  else
    CHROOT_MSG=
  fi

  echo $'\n****** Target system mounted at '"$TARGET $CHROOT_MSG"$'******\n'
  exit
fi

# Use the (largest) swap partition for hibernating
RESUME_UUID=
RESUME_FS_DEV=
MAX_SWAP_SIZE=0

for I in ${!FS_DEVS[@]}; do
  if [ "${FS_TYPES[$I]}" = 'swap' ]; then
    SWAP_SIZE=$(blockdev --getsize64 ${FS_DEVS[$I]})
    if [ $SWAP_SIZE -gt $MAX_SWAP_SIZE ]; then
      RESUME_FS_DEV=${FS_DEVS[$I]}
      RESUME_UUID=${FS_DEVS_UUIDS[$I]}
      MAX_SWAP_SIZE=$SWAP_SIZE
    fi
  fi
done

if [ "$RESUME_UUID" ]; then
  info "Using $RESUME_FS_DEV for hibernation"
  TARGET_PKGS="$TARGET_PKGS pm-utils"
fi


# -------------------- Install and configure target system ---------------

if [ "$INSTALL_GOAL" ]; then
  breakpoint "Target file system mounted at $TARGET, about to install a basic $DISTRIB_DESCRIPTION"

  # Install a basic Ubuntu, plus debconf-utils for debconf-get-selections
  # (needs 'universe' which might not be a package repository on the host)  
  require_pkg debootstrap

  debootstrap \
    --arch $(dpkg --print-architecture) \
    --components main,universe \
    --include language-pack-${LANG%%_*},debconf-utils \
    $DISTRIB_CODENAME $TARGET $REPO

  breakpoint "Basic $DISTRIB_DESCRIPTION installed, about to configure target system"

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

  # Write configuration files
  write_config_files

  # Save certain host debconf settings
  mkdir -p ${TARGET}/tmp
  DEBCONF=/tmp/debconf-selections
  on_exit "Removing temporary files: ${TARGET}/tmp/"'*' "rm -rf ${TARGET}/tmp/"'*'
  ${TARGET}/usr/bin/debconf-get-selections \
    | grep -E '^(tzdata|keyboard-configuration|console-data|console-setup)[[:space:]]' >${TARGET}$DEBCONF
  cp -fpR /etc/{localtime,timezone} /etc/default /etc/console-setup ${TARGET}/tmp

  # chroot into the target
  mount_devs
  info "Configuring target system: chrooting into $TARGET"

  if ! chroot $TARGET /bin/bash -l <<- EOF
    set -e
    export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true

    # Upgrade to the latest kernel version
    echo '--- Upgrading to the latest kernel version'
    apt-get -y -q update
    apt-get -y -q upgrade
    apt-get -y -q --reinstall --no-install-recommends install linux-image-generic linux-headers-generic linux-tools-generic

    # Set hostname
    echo '$TARGET_HOSTNAME' > /etc/hostname
    echo -e 'PRETTY_HOSTNAME=$TARGET_HOSTNAME\nICON_NAME=computer\nCHASSIS=desktop\nDEPLOYMENT=production' > /etc/machine-info
    sed -e 's/localhost/localhost $TARGET_HOSTNAME/' -i /etc/hosts

    # Install required packages
    echo '--- Installing required packages'
    locale-gen $LANG
    apt-get -y -q --no-install-recommends install \
      network-manager nano man-db plymouth-themes \
      console-data console-setup bash-completion fio grub-pc os-prober \
      $(sorted_unique $TARGET_PKGS)
      
    # Configure locale, timezone, console and keyboard (crude but working)
    update-locale LANG=$LANG LC_{ADDRESS,ALL,COLLATE,CTYPE,IDENTIFICATION,MEASUREMENT,MESSAGES,MONETARY,NAME,NUMERIC,PAPER,RESPONSE,TELEPHONE,TIME}=$LANG

    # Needed in addition to debconf-set-selections
    cp -fp /tmp/{localtime,timezone} /etc || true
    cp -fp /tmp/default/{keyboard,console-setup} /etc/default
    cp -fpR /tmp/console-setup /etc
    
    debconf-set-selections $DEBCONF
    for P in tzdata keyboard-configuration console-data console-setup; do
      dpkg-reconfigure -f noninteractive \$P
    done

    # Create user
    echo "--- Creating user '$TARGET_USERNAME'"
    useradd --create-home --groups adm,dialout,cdrom,floppy,sudo,audio,dip,video,plugdev,games,netdev --shell /bin/bash $TARGET_USERNAME
    echo '$TARGET_USERNAME:$TARGET_PWHASH' | chpasswd -e
EOF

  then
    die 'Target system configuration failed'
  fi
fi


# -------------------- Clone and reconfigure target system ---------------

if [ "$CLONE_GOAL" ]; then
  breakpoint "Target file system mounted at $TARGET, about to copy from '$SRC_DIR' on '${SRC_HOSTNAME:-$HOSTNAME}'"

  # Create rsync --exclude options for nodev file systems mounted below $SRC_DIR and for $TARGET
  AWK_EXCLUDE='$2 !~ "/dev/" { gsub("'$SRC_DIR'/?", "/", $1); printf "--exclude=%s/ ", $1; }'
  RSYNC_OPTS=$($SRC_PREAMBLE "$SSH_SOCKET" $SRC_HOSTNAME "findmnt -n -l -o TARGET,SOURCE -R $SRC_DIR | awk '$AWK_EXCLUDE'")
  RSYNC_OPTS="-avAHX --exclude=lost+found/ $RSYNC_OPTS"
  
  set -f        # do not expand wildcards in exclude paths
  for P in $SRC_EXCLUDES; do
    RSYNC_OPTS="$RSYNC_OPTS --exclude=$P"
  done
  set +f
  
  SRC_OPT=${SRC_DIR%/}/
  if [ "$SRC_HOSTNAME" ]; then
    SRC_OPT="${SRC_HOSTNAME}:${SRC_OPT}"
  
  else
    # Prevent $TARGET from being copied onto itself when cloning locally
    RSYNC_OPTS="$RSYNC_OPTS --exclude=$TARGET"
  fi

  # Copy the source, preserving hard links, permissions, ACLs and extended attributes
  # Hard links that would cross file system boundaries on the target cannot be preserved
  require_pkg rsync

  rsync -e "ssh -S '$SSH_SOCKET'" $RSYNC_OPTS $SRC_OPT $TARGET

  # Deinstall and (re-)install packages in chroot
  SRC_DESC=$(awk -F '="|=|"' '$1 == "DISTRIB_DESCRIPTION" { print $2 }' $TARGET/etc/lsb-release 2> /dev/null) || SRC_DESC='Unidentified OS'
  breakpoint "'$SRC_DESC' was copied, about to configure target system"

  # Write configuration files
  write_config_files

  mount_devs

  if ! chroot $TARGET /bin/bash -l <<- EOF
    set -e
    export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true

    # Purge packages related to the storage configuration of the source
    apt-get -y -q purge \
      {btrfs,nilfs,f2fs}-tools jfsutils reiserfsprogs xfsprogs ocfs2-* zfs-* \
      bcache-tools cachefilesd \
      mdadm lvm2 cryptsetup grub-pc os-prober

    # (Re-)Install only the required packages
    apt-get -y -q --reinstall --no-install-recommends install \
      $(sorted_unique $TARGET_PKGS) fio grub-pc os-prober
EOF

  then
    die 'Target system configuration failed'
  fi
fi


# ------------------------- Configure boot loader ------------------------

if ! chroot $TARGET /bin/bash -l <<- EOF
  set -e

  # Provide a localized keyboard after booting as early as possible
  # The GRUB keyboard layout is *not* localized because of questionable benefit, see these links for instructions:
  # http://askubuntu.com/questions/751259/how-to-change-grub-command-line-grub-shell-keyboard-layout#answer-751260
  # https://wiki.archlinux.org/index.php/Talk:GRUB#Custom_keyboard_layout
  LC=${LANG%%_*}
  cat >> /etc/default/grub <<-XEOF
GRUB_CMDLINE_LINUX="\\\$GRUB_CMDLINE_LINUX locale=\${LANG%%.*} bootkbd=\$LC console-setup/layoutcode=\$LC"
GRUB_GFXMODE=1920x1080,1440x900,1280x720,1280x1024,1024x768,800x600,640x480
XEOF

  # Handle an encrypted boot partition
  if [ -n "${ENCRYPTED[$BOOT_DEV_INDEX]}" -a "$AUTH_METHOD" = '1' ]; then
    # Note: GRUB_ENABLE_CRYPTODISK=1 is wrong
    echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
  fi

  # Do not let systemd handle encrypted partitions
  if [ "$AUTH_METHOD" ]; then
    cat >> /etc/default/grub <<-XEOF
GRUB_CMDLINE_LINUX="\\\$GRUB_CMDLINE_LINUX luks=no"
XEOF
  fi

  # Honor debug options
  case "$DEBUG_MODE" in
    1)
      # -d: disable os-prober and splash screen
      cat >> /etc/default/grub <<-XEOF
GRUB_CMDLINE_LINUX_DEFAULT=
GRUB_DISABLE_OS_PROBER=true
XEOF
      ;;
    2)
      # -dd: disable os-prober and splash screen, drop into initramfs
      cat >> /etc/default/grub <<-XEOF
# To drop into initramfs: break=top|modules|premount|mount|mountroot|bottom|init
GRUB_CMDLINE_LINUX="\\\$GRUB_CMDLINE_LINUX break=mount"
GRUB_CMDLINE_LINUX_DEFAULT=
GRUB_DISABLE_OS_PROBER=true
XEOF
      ;;
  esac

  # Prepare for resuming after hibernation if there is a swap partition
  if [ "$RESUME_UUID" ]; then
    cat >> /etc/default/grub <<-XEOF
GRUB_CMDLINE_LINUX_DEFAULT="\\\$GRUB_CMDLINE_LINUX_DEFAULT resume=UUID=$RESUME_UUID"
XEOF
  fi

  update-initramfs -c -k all
  update-grub

  # Install the boot loader on all devices that comprise /boot
  for B in $BOOT_DEVS; do
    echo '--- Installing boot loader on '\$B
    grub-install \$B
  done
EOF

then
  die 'Boot loader configuration failed'
fi

echo $'\n'"****** Target system mounted at $TARGET and ready to chroot ******"$'\n'
