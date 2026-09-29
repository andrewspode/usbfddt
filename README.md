# USBFDDT — USB Floppy Disk and Drive Tester

A Linux command-line utility for quickly testing 3.5" 1.44MB floppy drives and
disks over USB, and for copying disks to and from image files.

I made USBFDDT for testing floppy drives on the bench, using a readily available
USB-to-34-pin floppy adapter. It's far quicker than shutting down and
rebooting a vintage PC for every attempt. It's just as useful if you have an
ordinary USB floppy drive and want to check whether a disk is still usable.

USBFDDT was built with Claude, under my direction, over several months of
testing real drives, and tuned along the way for quick, effective use.

It was released alongside my article on
[how to service 3.5" floppy disk drives](https://spodesabode.com/articles/how-to-service-3-5-inch-floppy-disk-drives/),
which may help if your drives or disks are misbehaving.

## Features

- **Read test:** reads a known-good reference disk and compares it with its
  image.
- **Write test:** formats the disk, verifies it's blank, writes an image and
  verifies every sector. Can use a known image, or randomly filled data.
- **Image read and write:** copy your disks to file, or write them to new
  disks with verification.
- **Low-level formatting** via `ufiformat`, which often brings back disks with a
  damaged track 0 without needing a vintage PC.
- **Safe drive detection.** Finds USB floppy drives by their USB interface type
  (UFI), not by size, so card reader slots and flash drives are never picked.
  With more than one floppy drive connected, it makes you choose.
- **Confirms before erasing:** shows the drive and what's about to happen, and
  asks before anything touches the disk.
- **Handles automounting:** pauses the desktop's automounter while it works
  and turns it back on afterwards, even if interrupted (see
  [How it works](#how-it-works)).
- Checks for required tools before touching the disk, and uses clear exit codes
  for scripting.

## Limitations

- **Linux only.** A live USB of any common distro (e.g. Ubuntu) works fine if
  you don't normally run Linux.
- **USB floppy drives only**: a USB floppy drive, or a bare drive on a USB
  floppy adapter. Drives connected to a motherboard floppy controller
  (`/dev/fd*`) aren't supported.
- **1.44MB disks only.** Most USB floppy drives don't support 720K, and
  extended formats like DMF (1.68MB) aren't possible over USB at all.
- **A quick pass/fail check**, not a replacement for low-level tools like
  [ImageDisk](http://dunfield.classiccmp.org/img/) or flux-level tools like
  [Greaseweazle](https://github.com/keirf/greaseweazle) and KryoFlux. Use those
  when you need to analyse formats, alignment or copy protection.

## Requirements

- Linux, with a USB floppy drive or adapter
- Root access (`sudo`)
- These packages (Debian/Ubuntu names):

```bash
sudo apt install util-linux coreutils gddrescue diffutils ufiformat kmod
```

| Package | Provides | Needed for |
|---|---|---|
| util-linux, coreutils | `lsblk`, `blockdev`, `dd`, … | Everything |
| gddrescue | `ddrescue` | Everything except `format` |
| diffutils | `cmp` | `read-test`, `write-test`, `image-to-disk` |
| ufiformat, kmod | `ufiformat`, `modprobe` | `write-test`, `format`, `image-to-disk --format` |

The script checks for the tools each command needs and tells you what to
install if anything is missing.

## Installation

USBFDDT is a single self-contained script, so there's nothing to build: clone
the repository (or just copy `usbfddt.sh`) and run it.

```bash
git clone https://github.com/andrewspode/usbfddt.git
cd usbfddt

# See which drives are detected (reads nothing, doesn't need root)
./usbfddt.sh
```

### Running it from anywhere

To run USBFDDT from any directory, link the script into `/usr/local/bin`:

```bash
sudo ln -s "$PWD/usbfddt.sh" /usr/local/bin/usbfddt    # run from the repo folder
```

Then use `sudo usbfddt write-test` (and so on) from anywhere. The link points
at your clone, so `git pull` updates it. To remove it:
`sudo rm /usr/local/bin/usbfddt`.

Why a link rather than adding the repo folder to your `PATH`: the script always
runs under `sudo`, and `sudo` ignores your personal `PATH` in favour of a fixed
list of system folders, which includes `/usr/local/bin`. With only a `PATH`
change, `sudo usbfddt.sh` gives "command not found".

**Where files go:**

| File | Location |
|---|---|
| `source_disk.img` (the default image) | Next to the real script (your repo folder), wherever you run it from. The link is followed. `.gitignore` keeps images out of git |
| Any file you name, e.g. `disk-to-image mydisk.img` | Relative to your current directory, like any command |

For example, from `~/Downloads`:

```bash
sudo usbfddt write-test                   # uses source_disk.img from the repo folder
sudo usbfddt disk-to-image mydisk.img     # saves ~/Downloads/mydisk.img
sudo usbfddt image-to-disk other.img      # writes ~/Downloads/other.img
```

## Usage

```
usbfddt COMMAND [FILE] [OPTIONS]
```

Run with no arguments to list detected drives and show help.

**`write-test`, `image-to-disk` and `format` are destructive: everything on the
disk is erased.**

### Commands

| Command | What it does | Writes? |
|---|---|---|
| `read-test [IMAGE]` | Read the whole disk and compare it with IMAGE | No |
| `write-test [IMAGE]` | Format and verify blank, write IMAGE, read back and verify | Yes |
| `write-test --random` | The same, with new random data instead of an image. The strongest write test, but the disk isn't usable afterwards | Yes |
| `disk-to-image FILE` | Save the disk to an image file (won't overwrite an existing file) | No |
| `image-to-disk FILE` | Write an image file to the disk, read back and verify | Yes |
| `image-to-disk FILE --format` | The same, but format and verify blank first | Yes |
| `format` | Format and verify blank | Yes |

`IMAGE` defaults to `source_disk.img` next to the script, and must be exactly
1.44MB (1,474,560 bytes). `--random` and `--format` only work with the commands
shown; using them elsewhere is an error.

### Options for any command

| Option | What it does |
|---|---|
| `--device DEV` | Use this drive, e.g. `/dev/sdb`. Required if several USB floppy drives are connected |
| `-y`, `--yes` | Don't ask for confirmation before erasing a disk. Needed to run `write-test`, `image-to-disk` or `format` with no terminal to ask on (e.g. from another script) |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Failed: format, write, read or verify error |
| 2 | Nothing done: usage or setup error (bad arguments, missing tools, no drive found, write-protected disk, …), or cancelled at the confirmation |

## Testing drives and disks

### 1. Get a source image

You need a 1.44MB disk image, saved as `source_disk.img` next to the script.
Either:

- **Download one.** There are many floppy disk images online, such as this
  [Windows 98 SE boot disk](https://winworldpc.com/product/microsoft-windows-boot-disk/98-se),
  which is the one I use: you can never have too many boot disks lying around.
- **Make one** from a known-good disk in a known-good drive:

  ```bash
  sudo usbfddt disk-to-image source_disk.img    # run from the repo folder
  ```

### 2. Make a reference disk

A reference disk holds `source_disk.img`, written by a drive you trust. If you
made your image from a known-good disk, that disk already is one. Otherwise, in
a drive you trust:

```bash
sudo usbfddt write-test
```

Then slide the disk's write-protect tab so nothing can change it.

### 3. Test a drive

1. **Read test**, with the write-protected reference disk:

   ```bash
   sudo usbfddt read-test
   ```

   If this fails, the drive can't reliably read disks written by other drives.
2. **Write test**, with a scratch disk:

   ```bash
   sudo usbfddt write-test
   ```

   If the drive also passed the read test, the disk it just wrote is a good
   reference disk too.

If you strongly suspect a writing problem, use `write-test --random`, which
writes different data across every sector of the disk on every run.

### 4. Test a disk

Run `write-test` on it in a drive that passed both tests above. A disk that
fails in a known-good drive is the disk's fault.

**Always test a suspect drive with a known-good disk, and a suspect disk in a
known-good drive.** Otherwise you can't tell which one failed.

### Watch for marginal disks and drives

A test passes if every sector is eventually read correctly, but `ddrescue`
retries sectors that fail. Its progress display shows a **read errors** count:
if that's above zero on a passing test, some sectors only read after retrying.
The disk or drive is marginal: it works for now, but don't trust it.

For fixing drives that fail, see my
[article on servicing floppy drives](https://spodesabode.com/articles/how-to-service-floppy-disk-drives).

## How it works

**Writing.** Writing a floppy image with `dd bs=512` through the kernel's page
cache makes Linux *read* each 4KB block from the disk before writing part of it.
On a disk with any unreadable old data, those hidden reads fail and are
reported as write errors, often at different points on each run. USBFDDT writes
with `bs=36k oflag=direct`: whole cylinders, 4KB-aligned, bypassing the cache.
Progress is real and write errors are genuine write errors.

**Format and blank verification.** `ufiformat -V` formats the disk, then reads
every track back and checks every byte holds the same fill value. If the drive
silently failed to write, the old data is still there and the check fails. The
script flushes the device's cache first, so the check reads the disk itself
rather than data cached from before the format.

**Reading.** `ddrescue` reads the disk directly with retries. The script checks
ddrescue's map for sectors that were never recovered, because ddrescue itself
reports success even when some sectors couldn't be read. On a mismatch, the
first differing sector is reported.

**Detection.** USB floppy drives identify themselves with the UFI USB interface
subclass (`04`). Card readers, which also appear as empty `/dev/sdX` devices,
use a different subclass and are ignored. If no UFI drive is found (some
adapters don't identify themselves), USBFDDT falls back to a device of exactly
1.44MB, and asks you to choose with `--device` if there's more than one. With
`--device`, it still refuses anything that isn't a 1.44MB disk (or an empty
floppy drive, when formatting), so a mistyped device name can't wipe a hard
drive.

**Automounting.** Desktops mount floppy disks automatically, which could
interfere with a test: for example, grabbing the disk the moment a format or
write gives it a valid filesystem. So while USBFDDT runs, it unmounts the disk
if it's mounted, and stops the `udisks2` service (the automounter used by
GNOME, KDE, Xfce, Cinnamon, MATE and most other desktops). It says so when it
pauses and resumes automounting, since some desktops play a sound when this
happens.

- **udisks2 is started again automatically** when USBFDDT finishes or fails,
  and also if it's interrupted with Ctrl+C, a plain `kill`, or by closing the
  terminal. It's only stopped at all if it was running to begin with.
- **Only `kill -9` prevents the restart**, since nothing can run after it. In
  that case, run `sudo systemctl start udisks2`, or reboot.
- **Nothing else auto-mounts while a command runs**, since udisks2 is
  system-wide: a USB stick plugged in mid-test won't mount until USBFDDT
  finishes.
- **Only systemd-based distros** (Ubuntu, Pop!_OS, Mint, Debian, Fedora, Arch,
  openSUSE, …) are handled. On others, or with a different automounter, turn
  off automounting yourself before testing.

## License

MIT. See [LICENSE](LICENSE).
