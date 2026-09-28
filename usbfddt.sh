#!/bin/bash
#
# USBFDDT - USB Floppy Disk and Drive Tester
# https://github.com/andrewspode/usbfddt
# Copyright (c) 2026 Andrew Spode - MIT License (see LICENSE)
#
# Run with no arguments for help. See README.md for full documentation.

# Resolve symlinks, so a link in e.g. /usr/local/bin still finds the images
# next to the real script.
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
DEFAULT_IMAGE="$SCRIPT_DIR/source_disk.img"
DISK_SIZE=1474560   # 1.44MB: the only supported format

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

show_help() {
    cat <<EOF
USBFDDT - USB Floppy Disk and Drive Tester
https://github.com/andrewspode/usbfddt - (c) 2026 Andrew Spode, MIT License

Usage: $(basename "$0") COMMAND [FILE] [OPTIONS]

Commands:
  read-test [IMAGE]     Read and verify against IMAGE
  write-test [IMAGE]    Format with verify, write, read and verify
      --random          Use random data instead of an image
  disk-to-image FILE    Save the disk to FILE
  image-to-disk FILE    Write FILE to the disk, read and verify
      --format          Format with verify first
  format                Format with verify

IMAGE defaults to source_disk.img next to this script (1.44MB images only).

Options:
  --device DEV          Use this drive (required if several are connected)
  -y, --yes             Don't ask for confirmation before erasing a disk

Run with no arguments to list drives. See README.md for details.
EOF
}

usage() {
    show_help
    exit "${1:-2}"
}

# Usage or setup problem: nothing has been done to the disk.
die() {
    echo "ERROR: $*" >&2
    exit 2
}

# The disk or drive failed an operation.
fail() {
    echo >&2
    echo "FAIL: $*" >&2
    exit 1
}

# Start a new phase: a blank line, then the message, numbered when the
# command has several phases (e.g. "[2/3] Writing...").
step() {
    STEP=$((STEP + 1))
    echo
    if [ "$STEPS" -gt 1 ]; then
        echo "[$STEP/$STEPS] $*"
    else
        echo "$*"
    fi
}

success() {
    echo
    echo "SUCCESS: $*"
}

warn() {
    echo "WARNING: $*" >&2
}

# Files created while running as root via sudo go back to the real user.
give_to_user() {
    [ -n "$SUDO_USER" ] && chown "$SUDO_USER:" "$1"
}

# Check that the tools needed for the chosen command are installed. Each
# entry is "command:package".
check_deps() {
    local ITEM CMD PKG MISSING=()
    for ITEM in "$@"; do
        CMD=${ITEM%%:*}
        PKG=${ITEM#*:}
        if ! command -v "$CMD" >/dev/null; then
            # One entry per package, even if several of its commands are missing.
            [[ " ${MISSING[*]} " == *" $PKG "* ]] || MISSING+=("$PKG")
        fi
    done
    if [ "${#MISSING[@]}" -gt 0 ]; then
        die "Missing required tools. Install them first, e.g. on" \
            "Debian/Ubuntu: sudo apt install ${MISSING[*]}"
    fi
}

# Check that $1 is a usable 1.44MB image file.
check_image() {
    if [ ! -f "$1" ] && [ "$1" = "$DEFAULT_IMAGE" ]; then
        die "No image given, and the default $1 doesn't exist. Save a 1.44MB" \
            "disk image there (see README), name one on the command line, or" \
            "use write-test --random."
    fi
    [ -f "$1" ] || die "Image not found: $1"
    [ "$(stat -c %s "$1")" -eq "$DISK_SIZE" ] ||
        die "$1 is $(stat -c %s "$1") bytes; images must be exactly" \
            "$DISK_SIZE bytes (1.44MB)."
}

# True if DEV is a USB floppy drive: USB mass storage interface with the UFI
# subclass (04). Card readers and flash drives use other subclasses.
is_ufi() {
    local IF
    IF=$(readlink -f "/sys/block/$(basename "$1")/device" 2>/dev/null) || return 1
    while [ "$IF" != / ] && [ ! -f "$IF/bInterfaceSubClass" ]; do
        IF=$(dirname "$IF")
    done
    [ "$(cat "$IF/bInterfaceSubClass" 2>/dev/null)" = "04" ]
}

# List USB floppy drives, plus any other /dev/sdX the size-based fallback
# could pick (exactly 1.44MB). Uses only lsblk and sysfs, so it never reads
# from or writes to a disk and doesn't need root.
list_drives() {
    local FOUND=0 DEV SIZE MODEL NOTE
    echo "Drives found:"
    for DEV in /dev/sd?; do
        [ -b "$DEV" ] || continue
        SIZE=$(lsblk -dbno SIZE "$DEV" 2>/dev/null)
        [ -z "$SIZE" ] && continue
        MODEL=$(lsblk -dno VENDOR,MODEL "$DEV" 2>/dev/null | xargs)
        if is_ufi "$DEV"; then
            if [ "$SIZE" -eq 0 ]; then
                NOTE="USB floppy drive - no disk, or unreadable disk"
            else
                NOTE="USB floppy drive"
            fi
        elif [ "$SIZE" -eq "$DISK_SIZE" ]; then
            NOTE="not a UFI floppy drive - used only if no UFI drive is found"
        else
            continue
        fi
        printf '  %-9s %9s bytes  %-30s %s\n' "$DEV" "$SIZE" "$MODEL" "$NOTE"
        FOUND=1
    done
    [ "$FOUND" -eq 0 ] && echo "  None found."
    echo
}

# Set DEVICE to the floppy drive to use, or leave it empty if none is found.
find_device() {
    local DEV SIZE UFI_DEVS=()
    # Prefer drives that identify as USB floppy (UFI) drives, whatever size
    # they report: a disk with a damaged track 0 often reports 0 bytes.
    for DEV in /dev/sd?; do
        [ -b "$DEV" ] && is_ufi "$DEV" && UFI_DEVS+=("$DEV")
    done
    # With more than one drive, guessing could write to the wrong disk.
    if [ "${#UFI_DEVS[@]}" -gt 1 ]; then
        list_drives >&2
        die "${#UFI_DEVS[@]} USB floppy drives found (${UFI_DEVS[*]})." \
            "Choose one with --device, e.g. --device ${UFI_DEVS[0]}"
    fi
    if [ "${#UFI_DEVS[@]}" -eq 1 ]; then
        DEVICE="${UFI_DEVS[0]}"
        return
    fi
    # Fallback for adapters that don't report UFI: a /dev/sdX that is exactly
    # 1.44MB. Again, never guess between several.
    local SIZED=()
    for DEV in /dev/sd?; do
        SIZE=$(lsblk -dbno SIZE "$DEV" 2>/dev/null)
        [ "$SIZE" = "$DISK_SIZE" ] && SIZED+=("$DEV")
    done
    if [ "${#SIZED[@]}" -gt 1 ]; then
        list_drives >&2
        die "No USB floppy (UFI) drive found, and ${#SIZED[@]} 1.44MB devices" \
            "(${SIZED[*]}). Choose one with --device."
    fi
    if [ "${#SIZED[@]}" -eq 1 ]; then
        DEVICE="${SIZED[0]}"
        warn "No USB floppy (UFI) drive found; using 1.44MB device $DEVICE."
    fi
}

# Show what's about to be erased and ask to continue (default: no). $1
# describes the operation.
confirm() {
    local REPLY
    [ "$ASSUME_YES" -eq 1 ] && return
    [ -t 0 ] || die "No terminal to ask for confirmation on. Add --yes to" \
                    "run without confirming."
    echo
    echo "About to $1"
    echo "  Drive: $DEVICE - $(lsblk -dno VENDOR,MODEL "$DEVICE" 2>/dev/null | xargs)"
    echo "  Everything on the disk in this drive will be erased."
    read -r -p "Continue? [y/N] " REPLY
    case "$REPLY" in
        y|Y|yes|Yes|YES) ;;
        *)
            echo "Cancelled. Nothing was written."
            exit 2
            ;;
    esac
}

# Low-level format as 1.44MB, then have ufiformat read the whole disk back
# and check every byte is the same fill value (-V). If the drive can't write,
# the old data survives and the blank verification fails - even if the disk
# already held the image about to be written.
format_disk() {
    step "Formatting $DEVICE as 1.44MB and verifying it's blank..."
    # ufiformat -V reads through the page cache; drop anything cached from
    # before the format (e.g. the boot sector read when the disk went in), or
    # it could be compared against stale data.
    blockdev --flushbufs "$DEVICE"
    modprobe sg  # ufiformat talks to the drive through the SCSI generic driver
    if ! ufiformat -V -f 1440 "$DEVICE"; then
        fail "Format or blank verification failed (see above). \"no media\"" \
             "means no disk is inserted. \"bad value\" means the disk wasn't" \
             "blank after formatting: the drive may not be writing."
    fi
    # A disk that was unreadable before formatting may have reported a size
    # of 0, so make the kernel re-read the capacity before using it.
    echo 1 > "/sys/block/$(basename "$DEVICE")/device/rescan"
    blockdev --flushbufs "$DEVICE"
    SIZE=$(lsblk -dbno SIZE "$DEVICE" 2>/dev/null)
    [ "$SIZE" = "$DISK_SIZE" ] ||
        fail "After formatting, $DEVICE reports $SIZE bytes instead of $DISK_SIZE."
    echo "Format complete; disk is blank."
}

# Write image $1 to the disk. $2 is how to describe it.
write_disk() {
    step "Writing $2 to $DEVICE..."
    # bs=36k is two cylinders and a multiple of 4096, and oflag=direct
    # bypasses the page cache. Together they stop the kernel reading old disk
    # contents before each write (read-modify-write), which could fail with a
    # read error and be reported as a write failure.
    dd if="$1" of="$DEVICE" bs=36k oflag=direct conv=fdatasync \
        status=progress || fail "Write failed (I/O error)."
    echo "Write complete."
}

# Read the whole disk to $1 with retries. ddrescue exits 0 even when sectors
# stay unreadable, so check its map for anything not marked finished ('+').
read_disk() {
    local MAP="$WORK/read.map" BAD_BYTES=0 LEN STATUS
    rm -f "$1" "$MAP"
    # Reads are direct (-d), but drop any cached blocks for this device anyway.
    blockdev --flushbufs "$DEVICE"
    if ! ddrescue -r 3 -d "$DEVICE" "$1" "$MAP"; then
        echo "Read failed (ddrescue error)." >&2
        return 1
    fi
    # Skip comments and the first data line (current position), then add up
    # the (hex) sizes of every block that isn't '+'.
    while read -r _ LEN STATUS; do
        [ "$STATUS" != "+" ] && BAD_BYTES=$((BAD_BYTES + LEN))
    done < <(grep -v '^#' "$MAP" | tail -n +2)
    if [ "$BAD_BYTES" -gt 0 ]; then
        echo "$((BAD_BYTES / 512)) sector(s) could not be read." >&2
        return 1
    fi
}

# Read the whole disk back and compare it with image $1. $2 is how to
# describe it.
verify_disk() {
    local DIFF BYTE
    step "Reading $DEVICE and comparing with $2..."
    read_disk "$WORK/readback.img" || fail "Could not read the whole disk."
    if ! DIFF=$(cmp "$1" "$WORK/readback.img" 2>&1); then
        BYTE=$(echo "$DIFF" | sed -n 's/.*differ: byte \([0-9]*\).*/\1/p')
        if [ -n "$BYTE" ]; then
            fail "Mismatch: the disk differs from $2 at sector $(( (BYTE - 1) / 512 ))."
        fi
        fail "Mismatch: the disk differs from $2. ($DIFF)"
    fi
    echo "Disk matches $2."
}

cleanup() {
    [ -n "$WORK" ] && rm -rf "$WORK"
    if [ "$UDISKS_STOPPED" -eq 1 ]; then
        echo
        echo "Turning automounting back on (starting udisks2)..."
        systemctl start udisks2
    fi
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

COMMAND=""
FILE=""
USE_RANDOM=0
PRE_FORMAT=0
ASSUME_YES=0
DEVICE=""
WORK=""
UDISKS_STOPPED=0
STEP=0
STEPS=1   # number of phases the command runs, for "[n/total]"

if [ $# -eq 0 ]; then
    check_deps lsblk:util-linux
    show_help
    echo
    list_drives
    exit 0
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --random)      USE_RANDOM=1 ;;
        --format)      PRE_FORMAT=1 ;;
        -y|--yes)      ASSUME_YES=1 ;;
        --device)
            [ -z "$2" ] && die "--device needs a device, e.g. --device /dev/sdb"
            DEVICE="$2"
            shift
            ;;
        -h|--help) usage 0 ;;
        -*)
            echo "ERROR: Unknown option: $1" >&2
            usage
            ;;
        *)
            if [ -z "$COMMAND" ]; then
                COMMAND="$1"
            elif [ -z "$FILE" ]; then
                FILE="$1"
            else
                die "Unexpected argument: $1"
            fi
            ;;
    esac
    shift
done

[ -z "$COMMAND" ] && { echo "ERROR: No command given" >&2; usage; }

# Validate each command's file argument and options, and list the tools it
# needs. Formatting commands can work with a disk that reports 0 bytes.
DEPS=(lsblk:util-linux blockdev:util-linux stat:coreutils)
FORMATS=0
WRITES=0
case "$COMMAND" in
    read-test)
        [ "$USE_RANDOM" -eq 1 ] && die "--random only applies to write-test"
        [ "$PRE_FORMAT" -eq 1 ] && die "--format only applies to image-to-disk"
        FILE=${FILE:-$DEFAULT_IMAGE}
        check_image "$FILE"
        DEPS+=(ddrescue:gddrescue cmp:diffutils)
        ;;
    write-test)
        [ "$PRE_FORMAT" -eq 1 ] && die "write-test always formats; --format isn't needed"
        if [ "$USE_RANDOM" -eq 1 ]; then
            [ -n "$FILE" ] && die "Use either --random or an image, not both"
        else
            FILE=${FILE:-$DEFAULT_IMAGE}
            check_image "$FILE"
        fi
        FORMATS=1
        WRITES=1
        STEPS=3
        DEPS+=(ufiformat:ufiformat modprobe:kmod dd:coreutils
               ddrescue:gddrescue cmp:diffutils)
        ;;
    disk-to-image)
        [ "$USE_RANDOM" -eq 1 ] && die "--random only applies to write-test"
        [ "$PRE_FORMAT" -eq 1 ] && die "--format only applies to image-to-disk"
        [ -z "$FILE" ] && die "disk-to-image needs a file to save to"
        [ -e "$FILE" ] && die "$FILE already exists. Delete it or choose another name."
        DEPS+=(ddrescue:gddrescue)
        ;;
    image-to-disk)
        [ "$USE_RANDOM" -eq 1 ] && die "--random only applies to write-test"
        [ -z "$FILE" ] && die "image-to-disk needs an image file to write"
        check_image "$FILE"
        FORMATS=$PRE_FORMAT
        WRITES=1
        STEPS=$((2 + PRE_FORMAT))
        DEPS+=(dd:coreutils ddrescue:gddrescue cmp:diffutils)
        [ "$PRE_FORMAT" -eq 1 ] && DEPS+=(ufiformat:ufiformat modprobe:kmod)
        ;;
    format)
        [ "$USE_RANDOM" -eq 1 ] && die "--random only applies to write-test"
        [ "$PRE_FORMAT" -eq 1 ] && die "--format isn't needed with format"
        [ -n "$FILE" ] && die "format doesn't take a file"
        FORMATS=1
        WRITES=1
        DEPS+=(ufiformat:ufiformat modprobe:kmod)
        ;;
    *)
        echo "ERROR: Unknown command: $COMMAND" >&2
        usage
        ;;
esac

check_deps "${DEPS[@]}"

[ "$(id -u)" -eq 0 ] || die "Must be run as root (sudo)"

WORK=$(mktemp -d) || die "Could not create a temporary directory"
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Find and prepare the drive
# ---------------------------------------------------------------------------

if [ -n "$DEVICE" ]; then
    [ -b "$DEVICE" ] || die "$DEVICE is not a block device"
    # Resolve links like /dev/disk/by-id/... to the real /dev/sdX.
    DEVICE=$(readlink -f "$DEVICE")
    is_ufi "$DEVICE" || warn "$DEVICE is not detected as a USB floppy (UFI) drive."
else
    find_device
fi
if [ -z "$DEVICE" ]; then
    list_drives >&2
    die "No USB floppy drive found."
fi

SIZE=$(lsblk -dbno SIZE "$DEVICE" 2>/dev/null)
echo "Using floppy drive: $DEVICE (${SIZE} bytes)"

# Only a 1.44MB disk, or 0 bytes (no/unreadable disk) when about to format,
# is acceptable - this also guards against --device naming the wrong disk.
if [ -z "$SIZE" ]; then
    die "Could not read the size of $DEVICE."
elif [ "$SIZE" = 0 ]; then
    [ "$FORMATS" -eq 1 ] ||
        die "$DEVICE reports 0 bytes: no disk inserted, or the disk is" \
            "unreadable (e.g. damaged track 0). If you don't need what's on" \
            "it, '$(basename "$0") format' may recover it, but erases the disk."
elif [ "$SIZE" != "$DISK_SIZE" ]; then
    die "$DEVICE reports $SIZE bytes. Only 1.44MB ($DISK_SIZE bytes) disks" \
        "are supported."
fi

if [ "$WRITES" -eq 1 ] && [ "$(blockdev --getro "$DEVICE")" = 1 ]; then
    die "The disk in $DEVICE is write-protected. Slide the tab to allow" \
        "writing, or use a different disk."
fi

case "$COMMAND" in
    write-test)
        if [ "$USE_RANDOM" -eq 1 ]; then
            confirm "run a write test: format, write random test data, read back and verify."
        else
            confirm "run a write test: format, write $(basename "$FILE"), read back and verify."
        fi
        ;;
    image-to-disk)
        if [ "$PRE_FORMAT" -eq 1 ]; then
            confirm "format, write $(basename "$FILE"), read back and verify."
        else
            confirm "write $(basename "$FILE"), read back and verify."
        fi
        ;;
    format)
        confirm "format the disk and verify it's blank."
        ;;
esac

# Stop udisks2 so the desktop doesn't auto-mount or probe the disk mid-test,
# and start it again on exit - but only if it was running to begin with.
if command -v systemctl >/dev/null && systemctl is-active --quiet udisks2; then
    echo
    echo "Pausing automounting while this runs (stopping udisks2)..."
    systemctl stop udisks2 && UDISKS_STOPPED=1
fi

# Unmount the disk (or any partition on it) if mounted.
while read -r MNT; do
    echo "Unmounting $MNT..."
    umount "$MNT" || die "Could not unmount $MNT"
done < <(awk -v d="$DEVICE" '$1 == d || $1 ~ ("^" d "[0-9]+$") { print $1 }' /proc/mounts)

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

case "$COMMAND" in
    read-test)
        verify_disk "$FILE" "$(basename "$FILE")"
        success "Read test passed."
        ;;
    write-test)
        format_disk
        if [ "$USE_RANDOM" -eq 1 ]; then
            # New data every run, so it can't already be on the disk.
            head -c "$DISK_SIZE" /dev/urandom > "$WORK/random.img"
            write_disk "$WORK/random.img" "random test data"
            verify_disk "$WORK/random.img" "the random test data"
            success "Write test passed."
        else
            write_disk "$FILE" "$(basename "$FILE")"
            verify_disk "$FILE" "$(basename "$FILE")"
            success "Write test passed. The disk now holds $(basename "$FILE")."
        fi
        ;;
    disk-to-image)
        step "Saving $DEVICE to $FILE..."
        if ! read_disk "$FILE"; then
            if [ -s "$FILE" ]; then
                give_to_user "$FILE"
                fail "Some sectors couldn't be read, so $FILE is incomplete."
            fi
            rm -f "$FILE"
            fail "Couldn't read the disk. No image was saved."
        fi
        give_to_user "$FILE"
        success "Disk saved to $FILE."
        ;;
    image-to-disk)
        [ "$PRE_FORMAT" -eq 1 ] && format_disk
        write_disk "$FILE" "$(basename "$FILE")"
        verify_disk "$FILE" "$(basename "$FILE")"
        success "$(basename "$FILE") written and verified."
        ;;
    format)
        format_disk
        success "Disk formatted and verified blank."
        ;;
esac
