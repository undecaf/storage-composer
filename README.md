# StorageComposer

## Purpose
- __Creates and manages__ disk storage stacks under Ubuntu, from simple 
  (single partition) to complex (multiple drives/partitions, various file 
  systems, encryption, RAID and SSD caching in almost any combination).
- __Installs__ a (basic) Ubuntu onto the storage and makes it bootable, even if the
  storage is complex.
- __Clones__ an existing Ubuntu system and makes it bootable even on a different
  storage stack.

This project started as a simple script for setting up encrypted storage
for a few PCs. When RAID and caching joined in it got out of control somehow...


## :warning: WARNING WARNING WARNING :warning:
Please use this tool only if your are familiar with a Linux shell, disk
partitioning, file systems and with the terms and concepts mentioned in this
document.

StorageComposer might do things not intended by you that way, or it might even
malfunction badly and corrupt your data, therefore:

##### :warning: Please backup your data before you start using this tool.
##### :warning: Test thoroughly before you trust your storage.

## Proceed at your own risk

- [Usage](#usage)
  - [What you need](#what-you-need)
  - [Disk partitioning](#disk-partitioning)
  - [Running StorageComposer](#running-storagecomposer)
    - [Building, installing and cloning](#building-installing-and-cloning)
    - [Mounting](#mounting)
    - [Unmounting](#unmounting)
    - [Help](#help)
  - [Configuring the target system](#configuring-the-target-system)
    - [File systems](#file-systems)
    - [Authorization](#authorization)
    - [Global settings](#global-settings)
    - [Installing](#installing)
    - [Cloning](#cloning)
  - [Is it reliable? Testing](#is-it-reliable-testing)
    - [Running tests](#running-tests)
    - [Customize testing](#customize-testing)
- [Examples](#examples)
  - [Plain file systems](#plain-file-systems)
    - [Backup or media storage with ext4](#backup-or-media-storage-with-ext4)
    - [Bootable btrfs with subvolumes](#bootable-btrfs-with-subvolumes)
    - [Bootable with OS on SSD, various file systems](#bootable-with-os-on-ssd-various-file-systems)
   - [RAID](#raid)
     - [Bootable RAID1](#bootable-raid1)
     - [Accelerated RAID1 of SSDs and HDDs](#accelerated-raid1-of-ssds-and-hdds)
     - [Everything RAIDed](#everything-raided)
   - [Encryption](#encryption)
     - [Encrypted backup storage](#encrypted-backup-storage)
     - [“Fully encrypted” bootable system with RAIDs](#fully-encrypted-bootable-system-with-raids)
   - [Caching](#caching)
     - [Basic caching](#basic-caching)
     - [Caching a (slow) bootable, encrypted RAID6](#caching-a-slow-encrypted-raid6)
     - [Caching multiple encrypted file systems on the same SSD](#caching-multiple-encrypted-file-systems-on-the-same-ssd)
- [FAQ](#faq)
- [Missing features](#missing-features)
- [Licenses](#licenses)
- [References and credits](#references-and-credits)
    
## Usage

### What you need
StorageComposer consists of a bash script and a few helper files. Currently it
requires Ubuntu Xenial or one of its variants. If no such OS is installed on
your PC or if you wish to set up a bare-metal system, boot from an Ubuntu Xenial
live DVD first.

Download all `stcomp.*` files to the same directory and make sure that `stcomp.sh`
is executable.

### Disk partitioning
Storage disks and caching SSDs must be partitioned before running StorageComposer, e.g. using
`fdisk`, `gdisk`, `parted`, `GParted`, `QtParted` or similar tools.
Those partitions do not need to have any file system type assigned, nor
do they have to be formatted&nbsp;&ndash; StorageComposer will take care of that. 

### Running StorageComposer
StorageComposer must be run from a regular user account in `sudo` as `root`.
The system running StorageComposer is referred to as __“host system”__ or
__“host”__; the storage managed by StorageComposer is called the __“target system”__
or __“target”__.

Depending on the command line arguments, one of these tasks is performed:

#### Building, installing and cloning
__`sudo stcomp.sh -b [-i|-c] [-d] `__
<b><code>[[&lt;config&#x2011;file&gt;]](#configuring-the-target-system)</code></b>

Builds&nbsp;(`-b`) a new target system, mounts it at a directory on
the host system and prepares to `chroot` into this directory.
Existing data on the underlying target partitions is lost.

An internet connection is required; see here for details:
[Does StorageComposer alter the system on which it is run?](#does-storagecomposer-alter-the-host-system-on-which-it-is-run)
  
If desired then StorageComposer can make your target bootable by:
- [__installing__](#installing)&nbsp;(`-i`) a basic Ubuntu system
  from the Ubuntu repositories, or
- [__cloning__](#cloning)&nbsp;(`-i`) an existing local or remote Ubuntu system:
  this copies the directory tree of the source system to the target. Then the target
  is reconfigured according to its storage configuration.
    
Diagnostic messages&nbsp;(`-d`) can be displayed during building and also when
booting the target.  

#### Mounting
__`sudo stcomp.sh -m [-i|-c] [-y] [-d]`__
<b><code>[[&lt;config&#x2011;file&gt;]](#configuring-the-target-system)</code></b>

Mounts&nbsp;(`-m`) a previously built target system and prepares it for 
`chroot`-ing. Optionally, `-i`&nbsp;[installs Ubuntu](#installing) 
and&nbsp;`-c`&nbsp;[clones an existing system](#cloning).
This will overwrite data on the target devices.

`-y`&nbsp;mounts (but does not install or clone) without user interaction,
`-d`&nbsp;prints diagnostic messages.


#### Unmounting
__`sudo stcomp.sh -u [-y] `__
<b><code>[[&lt;config&#x2011;file&gt;]](#configuring-the-target-system)</code></b>

Unmounts a target system from its current mount point on the host system.
Use&nbsp;`-y` for unattended unmounting.  

#### Help  
 __`stcomp.sh -h`__ displays a help message.
  

### Configuring the target system
Target configuration is specified interactively and is saved to/loaded from a
<code>&lt;config&#x2011;file&gt;</code>. If omitted from the command line, 
<code>&lt;config&#x2011;file&gt;</code> defaults to `~/.stcomp.conf`.
A separate <code>&lt;config&#x2011;file&gt;</code> should be kept for each
target system that is managed by StorageComposer.

Configuration options are entered/edited strictly sequentially (_sigh_) in the
order of the following sections. Each option defaults to what was last saved to
the <code>&lt;config&#x2011;file&gt;</code>.

For each option, entering `?` will indicate what is a valid input.

#### File systems
Each target system _must have_ a root file system and _can have_ additional file
systems. If the target is bootable and is running then the root file system appears
at `/`. If the target is mounted in the host then the root file system
appears at the [`Target mount point`](#global-settings).
In either case, additional file systems are mounted relative to the root file system.

The root file system has to be configured first. More file systems can be added
afterwards. For each file system, the following prompts appear in this order:

<dl>
  <dt><code>Partition(s) for root file system (two or more make a RAID):</code>, or<br>
  <code>Partition(s) for additional file system (two or more make a RAID, empty 
  to continue):</code></dt>
  <dd><p>Enter the partition(s) that make up this file system, separated by space.
  Leading <code>/dev/</code> path components may be omitted for brevity, e.g.
  <code>sde1</code> is equivalent to <code>/dev/sde1</code>.</p></dd>
  
  <dt><code>RAID level:</code></dt>
  <dd><p>If several partitions were specified then an
  <a href="https://raid.wiki.kernel.org/index.php/Linux_Raid">MD/RAID</a> will be
  built from these components. Enter the RAID level (<code>0</code>, <code>1</code>,
  <code>4</code>, <code>5</code>, <code>6</code> or <code>10</code>). The minimum
  number of components for each level is 2, 2, 3, 3, 4 and 4, respectively.</p>
  <p>A RAID1 consisting of both SSDs and HDDs will prefer reading from the SSDs.
  This performs similar to an SSD cache.</dd>
  
  <dt><code>SSD caching device (optional):</code></dt>
  <dd><p>If a partition is specified then it will become a 
  <a href="https://bcache.evilpiepirate.org/">bcache</a> caching device
  for this file system. Swap space must not be cached. The same partition can
  act as a cache for several file systems.</p></dd>
  
  <dt><code>Erase block size:</code></dt>
  <dd><p>Optimum caching performance (supposedly?) depends on choosing the correct
  <a href="https://wiki.linaro.org/WorkingGroups/KernelArchived/Projects/FlashCardSurvey#Erase_blocks_and_GC_Units">erase block</a> size for your SSD
  (one of <code>64k</code>, <code>128k</code>, ... <code>16M</code>,
  <code>32M</code> or <code>64M</code>).
  SSD data sheets usually do not contain this information, but
  <a href="https://wiki.linaro.org/WorkingGroups/KernelArchived/Projects/FlashCardSurvey#List_of_flash_memory_cards_and_their_characteristics">this survey</a>
  may be helpful. If in doubt, <code>64M</code> is the safest guess but may lead
  to poorer cache space utilization. On the other hand, selecting too small an
  erase block size decreases cache write performance.</p></dd>
  
  <dt><code>LUKS-encrypted (y/n)?</code></dt>
  <dd><p>Will encrypt the partitions of this file system using
  <a href="https://en.wikipedia.org/wiki/Dm-crypt">dm-crypt</a>/<a href="https://en.wikipedia.org/wiki/Linux_Unified_Key_Setup">LUKS</a>.
  The caching device will only see encrypted data.
  All encrypted file systems share the same LUKS passphrase (see section
  <a href="#authorization">Authorization</a>).</p>
  <p>If the target system is bootable and <code>/boot</code> is on an encrypted
  file system then only a conventional passphrase can be used for authorization
  since key files are not supported by GRUB2.</p></dd>
  
  <dt><code>File system:</code></dt>
  <dd><p>Select one of <code>ext2</code>, <code>ext3</code>, <code>ext4</code>,
  <code>btrfs</code> or <code>xfs</code>. For additional file systems, 
  <code>swap</code> is also available.</p></dd>
  
  <dt><code>Mount point:</code>, or<br>
  <code>Mount points (become top-level subvolumes with leading '@'):</code></dt>
  <dd><p>Enter one or several (only btrfs) mount points, separated by space.
  For each btrfs mount point, a corresponding subvolume will be created. 
  The root file system must have mount point <code>/</code>.</p></dd>
  
  <dt><code>Mount options (optional):</code></dt>
  <dd><p>Become effective for this file system whenever the target system is
  mounted at the <a href="#miscellaneous"><code>Target mount point</code></a>
  in the host and also when booting from the target.</p></dd>
</dl>

#### Authorization
If any target file system is encrypted then you need to specify how to
authorize for opening it. The same LUKS passphrase is used for all encrypted 
file systems. Salting guarantees that each file system is still encrypted
with a different key. The LUKS passphrase can be a conventional passphrase or the
content of a file, see below.
 
<dl>
  <dt><code>LUKS authorization method:</code></dt>
  <dd><p>This determines what to use as LUKS passphrase for creating or opening
  	an encrypted file system when building, mounting or booting a target system:
  	<ol>
  	  <li>a conventional <b>passphrase</b> that has to be typed in at the keyboard</li>
  	  <li>a <b>key file</b> with the following properties:
  	    <ul>
  	      <li>arbitrary (preferably random) content</li>
  	      <li>size between 256 and 8192 bytes</li>
  	      <li>can be on a LUKS-encrypted partition. When <i>booting</i>, the user will be
	  	      prompted for the LUKS partition passphrase. Before <i>building</i> or
	  	      <i>mounting</i> such a target in the host system, you must open the
	  	      LUKS-encrypted partition yourself, e.g. using
	          <a href="http://manpages.ubuntu.com/manpages/xenial/man8/cryptsetup.8.html"><code>cryptsetup</code></a> or your file manager.</li>
  	    </ul>
  	  </li>
  	  <li>an <b>encrypted key file</b> with the following properties:
  	  	<ul>
  	      <li>arbitrary content</li>
  	      <li>decrypted size between 256 and 8192 bytes</li>
  	  	  <li><a href="https://www.gnupg.org/gph/en/manual.html">GPG-encrypted</a></li>
  	  	</ul>
  	  	When booting, building or mounting such a target, the user will be
  	  	prompted for the key file passphrase.
  	  </li>
  	</ol></p>
    <p>You can create a key file yourself or have StorageComposer create one with
    random content, see below. Keeping that file on a removable device (USB stick,
    MMC card) provides
    <a href="https://en.wikipedia.org/wiki/Multi-factor_authentication">two-factor authentication</a>.</p></dd>

  <dt><code>Key file (preferably on a mounted removable device):</code>, or<br>
  <code>Encrypted key file (preferably on a mounted removable device):</code></dt>
  <dd><p>Enter the absolute path of the key file. If the file does not exist you will
  be asked whether to have one created.</p>
  <p><b>Caution:</b> always keep a copy of your key file offline in a
  safe place.</p></dd>

  <dt><code>LUKS passphrase:</code>, or<br>
  <code>Key file passphrase:</code></dt>
  <dd><p>Appears whenever a passphrase is required for LUKS authorization 
  methods&nbsp;1 and&nbsp;3. When building a target, each passphrase must
  be repeated for verification.
  The most recent passphrase per <code>&lt;config&#x2011;file&gt;</code> and
  authorization method is remembered for five&nbsp;minutes. Within that time,
  it does not have to be retyped and can be used for
  <a href="#mounting">unattended mounting</a>
  (<code>-m&nbsp;-y</code>).</p></dd>
</dl>

#### Global settings
These options affect all file systems.
<dl>
  <dt><code>Prefix to mapper names and labels (recommended):</code></dt>
  <dd><p>The first mount point of each file system without the leading <code>/</code>
  (<code>root</code> for the root file system) serves as volume label,
  MD/RAID device name and <code>/dev/mapper</code> name.</p>
  <p>The prefix specified here is prepended to these labels and names in order to
  avoid name conflicts with the host system.</p></dd>

  <dt><code>Target mount point:</code></dt>
  <dd><p>Absolute path to a host directory where to mount the target system.</p>
  <p>In order to be able to <code>chroot</code>, these special host paths are
  <a href="http://manpages.ubuntu.com/manpages/xenial/man8/mount.8.html">bind-mounted</a>
  automatically: <code>/dev</code>, <code>/dev/pts</code>, <code>/proc</code>, <code>/run/resolvconf</code>, <code>/run/lock</code>, <code>/sys</code>.</p></dd>
</dl>

#### Installing
These prompts appear only if you
[install Ubuntu](#building-installing-and-cloning) on the target system:

<dl>
  <dt><code>Hostname:</code></dt>
  <dd><p>Determines the hostname of the target when it is running.</p></dd>

  <dt><code>Username (empty to copy host user):</code>,<br>
  <code>Login passphrase:</code></dt>
  <dd><p>Defines the user account to create on the target system. For 
  convenience, username and passphrase of the current host user (the one running
  <code>sudo&nbsp;stcomp.sh</code>) can be copied to the target.</p></dd>
</dl>

Other settings are inherited from the host system:
- architecture (`x86` or `amd64`)
- distribution version (`Xenial` etc.)
- main Ubuntu package repository
- locale
- time zone
- keyboard configuration
- console setup (character set and font)

#### Cloning
When [cloning a directory](#building-installing-and-cloning) containing an Ubuntu
system, the source directory tree is copied to the target and the target system
is reconfigured so that it can boot from its storage.

Please note these requirements:

- All _device_ file systems of the source system _must be mounted_ at the source
  directory. An additional instance of StorageComposer may be helpful if the
  source storage stack is complex.
- Source subdirectories containing _no-device_ file systems such as `proc`,
  `sysfs`, `tmpfs` etc. are not copied.
- The source system _should not be running_. Otherwise, the target may end up
  in an inconsistent state. Consequently, there should be a running system
  containing the source directory as a subdirectory, i.e. not `/`.
- If the source directory is remote then
  <a href="http://manpages.ubuntu.com/manpages/xenial/en/man1/rsync.1.html">rsync</a>
  and an <a href="https://help.ubuntu.com/community/SSH">SSH server</a>
  must be installed at the remote host.

<dl>
  <dt><code>Remote host to clone from (empty for a local directory):</code></dt>
  <dd><p>A hostname or an IP address are required here if you wish to 
  clone a remote directory. Leaving this empty will skip the following 
  <b><i>Remote...</i></b> prompts.</dd>

  <dt><code>Remote SSH port:</code></dt>
  <dd><p>The port at which the remote SSH server is listening.</p></dd>

  <dt><code>Remote username (required only if password authentication):</code></dt>
  <dd><p>Enter the remote username for password-based authentication. The
  password prompt will appear later in the process.
  Leave this field empty if the host uses a non-interactive authentication method,
  e.g. public key authentication.</p>
  <p>The authenticated user needs sufficient privileges to read everything within the
  remote source directory.</p></dd>

  <dt><code>Remote directory to clone from:</code>, or<br>
  <code>Directory to clone from:</code></dt>
  <dd><p>The directory where the storage of the source system is mounted. The
  source system should be an Ubuntu release supported by StorageComposer but it
  <i>should not be running</i>. Otherwise, the target may end up in an
  inconsistent state.
  </p></dd>
</dl>

Since the target storage configuration may differ from the source, please be
aware of these restrictions:
- All filesystem-related packages that are required for the target storage are
  reconfigured from scratch. Excess file system packages copied from the source are purged
  from the target, see
  [Which packages can be affected by cloning?](#which-packages-can-be-affected-by-cloning)
- Custom GRUB2 configuration options are lost.
- Swap space is not cloned, and the target swap space remains empty.
- Hard links that would cross file system boundaries on the target system are
  not preserved.
- Target device names and UUIDs will be different from the source. This can break
  existing scripts. Files required for booting such as `/etc/fstab` etc. are
  adjusted by StorageComposer. 

### Is it reliable? Testing
Whenever a target is built (`-b`) or mounted (`-m)`, a script for testing
the target storage is created. On the host, it is located in the same directory
as the `<config-file>` but has&nbsp;`-test.sh` appended to the name.
On bootable targets a copy is saved as `/usr/local/sbin/stcomp-test.sh`.

The following tests run on all subvolumes, file systems and swap devices that
are part of the target:
- Basic data verification: data is written randomly and then read back and
  verified.
- Sequential read/write performance
- Simulated file server performance: data is written and read randomly. Reads happen
  more frequently than writes.

Testing is non-destructive on file systems and subvolumes but creates several
files that can be huge. To delete them, run the test script with option&nbsp;`-c`.  
Swap space is overwritten by testing. If necessary, it is disabled 
automatically (`swapoff`) and re-enabled thereafter (`swapon`).
  
#### Running tests

- __Testing from within the host file system__  
  Mount the target beforehand if necessary:
  __`sudo stcomp.sh -m <config-file>`__  
  Then start the test: __`sudo <config-file>-test.sh`__
- __Testing `chroot`-ed__ at the [Target mount point](#global-settings) or __in
  the running target system__  
  Command line: __`sudo stcomp-test.sh`__

Please disregard the warnings `Multiple writers may overwrite blocks that belong to other jobs` appearing at the beginning. In some cases, the ETA
in the status line can also be misleading. Invoke the test script with 
option&nbsp;`-h` for help on how to limit the script runtime and on other
options.

The testing backend&nbsp;&ndash; the “Flexible I/O Tester” (fio)&nbsp;&ndash; is
very powerful and produces detailed results. Please refer to section&nbsp;6
(“Normal output”) of the [fio Howto](https://github.com/axboe/fio/blob/master/HOWTO)
or to the
[fio manpage](http://manpages.ubuntu.com/manpages/xenial/en/man1/fio.1.html)
for an explanation of the output. 

#### Customize testing

In order to add your own tests or modify existing ones, you need to be familiar
with the fio job file format and parameters, see sections&nbsp;4 
(“Job file format”) and&nbsp;5 (“Detailed list of parameters”) of the
[fio Howto](https://github.com/axboe/fio/blob/master/HOWTO) or the
[fio manpage](http://manpages.ubuntu.com/manpages/xenial/en/man1/fio.1.html).

Custom tests can be added to a section marked as such close to the end of the
test script. Please __make a copy of the modified script__ because the original
`<config-file>-test.sh` will be overwritten whenever the target is mounted.

## Examples
Target drives used in these examples start at `/dev/sde`. Drives are hard disks unless
marked `USB` (removable USB device) or `SSD` (non-removable SSD device).

### Plain file systems
Only shown for completeness, these examples can also be achieved with other
(more user-friendly) tools.

#### Backup or media storage with ext4
Under-exciting, just for starters...
<table align="center">
	<tr>
		<th align="left">File systems</th>
		<td align="center">ext4</td>
	</tr>
	<tr>
		<th align="left">Mount points</th>
		<td align="center"><code>/</code></td>
	</tr>
	<tr>
		<th align="left">Partitions</th>
		<td align="center"><code>sde1</code></td>
	</tr>
	<tr>
		<th align="left">Drives</th>
		<td align="center"><code>sde</code></td>
	</tr>
</table>

#### Bootable btrfs with subvolumes
Similar to what might be done easily with the Ubuntu Live DVD installer.
<table align="center">
	<tr>
		<th align="left">File systems</th>
		<td align="center" colspan="2">btrfs</td>
		<td align="center">swap</td>
	</tr>
	<tr>
		<th align="left">Subvolumes</th>
		<td align="center"><code>@</code></td>
		<td align="center"><code>@home</code></td>
		<td align="center"></td>
	</tr>
	<tr>
		<th align="left">Mount points</th>
		<td align="center"><code>/</code></td>
		<td align="center"><code>/home</code></td>
		<td align="center"></td>
	</tr>
	<tr>
		<th align="left">Partitions</th>
		<td align="center" colspan="2"><code>sde1</code></td>
		<td align="center"><code>sde2</code></td>
	</tr>
	<tr>
		<th align="left">Drives</th>
		<td align="center" colspan="3"><code>sde</code></td>
	</tr>
	<tr>
		<th align="left">MBR</th>
		<td align="center" colspan="3">yes</td>
	</tr>
</table>

#### Bootable with OS on SSD, various file systems
Boots from SSD, has the OS on SSD and data and swap space on HDD.
<table align="center">
	<tr>
		<th align="left">File systems</th>
		<td align="center">ext4</td>
		<td align="center" colspan="2">btrfs</td>
		<td align="center">swap</td>
	</tr>
	<tr>
		<th align="left">Subvolumes</th>
		<td align="center"></td>
		<td align="center"><code>@home</code></td>
		<td align="center"><code>@var</code></td>
		<td align="center"></td>
	</tr>
	<tr>
		<th align="left">Mount points</th>
		<td align="center"><code>/</code></td>
		<td align="center"><code>/home</code></td>
		<td align="center"><code>/var</code></td>
		<td align="center"></td>
	</tr>
	<tr>
		<th align="left">Partitions</th>
		<td align="center"><code>sde1</code></td>
		<td align="center" colspan="2"><code>sdf1</code></td>
		<td align="center"><code>sdf2</code></td>
	</tr>
	<tr>
		<th align="left">Drives</th>
		<td align="center"><code>sde</code><br>(SSD)</td>
		<td align="center" colspan="3"><code>sdf</code></td>
	</tr>
	<tr>
		<th align="left">MBR</th>
		<td align="center">yes</td>
		<td align="center" colspan="3"></td>
	</tr>
</table>


### RAID

#### Bootable RAID1
Everything is on a RAID1 except for swap space.
<table align="center">
	<tr>
		<th align="left">File systems</th>
		<td align="center" colspan="2">ext4</td>
		<td align="center">swap</td>
	</tr>
	<tr>
		<th align="left">Subvolumes</th>
		<td align="center" colspan="2"></td>
		<td align="center"></td>
	</tr>
	<tr>
		<th align="left">Mount points</th>
		<td align="center" colspan="2"><code>/</code></td>
		<td align="center"></td>
	</tr>
	<tr>
		<th align="left">RAID arrays</th>
		<td align="center" colspan="2">RAID1</td>
		<td align="center"></td>
	</tr>
	<tr>
		<th align="left">Partitions</th>
		<td align="center"><code>sde1</code></td>
		<td align="center"><code>sdf1</code></td>
		<td align="center"><code>sdg1</code></td>
	</tr>
	<tr>
		<th align="left">Drives</th>
		<td align="center"><code>sde</code></td>
		<td align="center"><code>sdf</code></td>
		<td align="center"><code>sdg</code></td>
	</tr>
	<tr>
		<th align="left">MBR</th>
		<td align="center" colspan="2">yes</td>
		<td align="center"></td>
	</tr>
</table>

#### Accelerated RAID1 of SSDs and HDDs
If a RAID1 has both SSD as well as HDD components, SSDs are used for reading (if
possible), and write-behind is activated on the HDDs. Performance is comparable
to an SSD.
<table align="center">
	<tr>
		<th align="left">File systems</th>
		<td align="center" colspan="2">xfs</td>
		<td align="center">swap</td>
	</tr>
	<tr>
		<th align="left">Subvolumes</th>
		<td align="center" colspan="2"></td>
		<td align="center"></td>
	</tr>
	<tr>
		<th align="left">Mount points</th>
		<td align="center" colspan="2"><code>/</code></td>
		<td align="center"></td>
	</tr>
	<tr>
		<th align="left">RAID arrays</th>
		<td align="center" colspan="2">RAID1</td>
		<td align="center"></td>
	</tr>
	<tr>
		<th align="left">Partitions</th>
		<td align="center"><code>sde1</code></td>
		<td align="center"><code>sdf1</code></td>
		<td align="center"><code>sdf2</code></td>
	</tr>
	<tr>
		<th align="left">Drives</th>
		<td align="center"><code>sde</code></td>
		<td align="center" colspan="2"><code>sdf</code><br>(SSD)</td>
	</tr>
	<tr>
		<th align="left">MBR</th>
		<td align="center">yes</td>
		<td align="center" colspan="2">yes</td>
	</tr>
</table>

#### Everything RAIDed
Boots from SSD, has the OS on SSD and data and swap space on HDD. Everything is
on RAID arrays, even swap space.
<table align="center">
	<tr>
		<th align="left">File systems</th>
		<td align="center" colspan="3">ext4</td>
		<td align="center" colspan="2">btrfs</td>
		<td align="center" colspan="2">swap</td>
	</tr>
	<tr>
		<th align="left">Subvolumes</th>
		<td align="center" colspan="3"></td>
		<td align="center"><code>@home</code></td>
		<td align="center"><code>@var</code></td>
		<td align="center" colspan="2"></td>
	</tr>
	<tr>
		<th align="left">Mount points</th>
		<td align="center" colspan="3"><code>/</code></td>
		<td align="center"><code>/home</code></td>
		<td align="center"><code>/var</code></td>
		<td align="center" colspan="2"></td>
	</tr>
	<tr>
		<th align="left">RAID arrays</th>
		<td align="center" colspan="3">RAID5</td>
		<td align="center" colspan="2">RAID1</td>
		<td align="center" colspan="2">RAID0</td>
	</tr>
	<tr>
		<th align="left">Partitions</th>
		<td align="center"><code>sde1</code></td>
		<td align="center"><code>sdf1</code></td>
		<td align="center"><code>sdg1</code></td>
		<td align="center"><code>sdh1</code></td>
		<td align="center"><code>sdi1</code></td>
		<td align="center"><code>sdh2</code></td>
		<td align="center"><code>sdi2</code></td>
	</tr>
	<tr>
		<th align="left">Drives</th>
		<td align="center"><code>sde</code><br>(SSD)</td>
		<td align="center"><code>sdf</code><br>(SSD)</td>
		<td align="center"><code>sdg</code><br>(SSD)</td>
		<td align="center"><code>sdh</code></td>
		<td align="center"><code>sdi</code></td>
		<td align="center"><code>sdh</code></td>
		<td align="center"><code>sdi</code></td>
	</tr>
	<tr>
		<th align="left">MBR</th>
		<td align="center" colspan="3">yes</td>
		<td align="center" colspan="2"></td>
		<td align="center" colspan="2"></td>
	</tr>
</table>


### Encryption

#### Encrypted backup storage
Could be used for making backups of an encrypted system.
<table align="center">
	<tr>
		<th align="left">File systems</th>
		<td align="center">xfs</td>
	</tr>
	<tr>
		<th align="left">Subvolumes</th>
		<td align="center"></td>
	</tr>
	<tr>
		<th align="left">Mount points</th>
		<td align="center"><code>/</code></td>
	</tr>
	<tr>
		<th align="left">LUKS encryption</th>
		<td align="center">yes</td>
	</tr>
	<tr>
		<th align="left">RAID arrays</th>
		<td align="center"></td>
	</tr>
	<tr>
		<th align="left">Partitions</th>
		<td align="center"><code>sde1</code></td>
	</tr>
	<tr>
		<th align="left">Drives</th>
		<td align="center"><code>sde</code></td>
	</tr>
	<tr>
		<th align="left">MBR</th>
		<td align="center"></td>
	</tr>
</table>

#### “Fully encrypted” bootable system with RAIDs
Boots from a RAID1, has data in a RAID5 and swap space in a RAID0.
<table align="center">
	<tr>
		<th align="left">File systems</th>
		<td align="center" colspan="2">ext2</td>
		<td align="center" colspan="3">btrfs</td>
		<td align="center" colspan="2">swap</td>
	</tr>
	<tr>
		<th align="left">Subvolumes</th>
		<td align="center" colspan="2"></td>
		<td align="center"><code>@</code></td>
		<td align="center"><code>@home</code></td>
		<td align="center"><code>@var</code></td>
		<td align="center" colspan="2"></td>
	</tr>
	<tr>
		<th align="left">Mount points</th>
		<td align="center" colspan="2"><code>/boot</code></td>
		<td align="center"><code>/</code></td>
		<td align="center"><code>/home</code></td>
		<td align="center"><code>/var</code></td>
		<td align="center" colspan="2"></td>
	</tr>
	<tr>
		<th align="left">LUKS encryption</th>
		<td align="center" colspan="2"></td>
		<td align="center" colspan="3">yes</td>
		<td align="center" colspan="2">yes</td>
	</tr>
	<tr>
		<th align="left">RAID arrays</th>
		<td align="center" colspan="2">RAID1</td>
		<td align="center" colspan="3">RAID5</td>
		<td align="center" colspan="2">RAID0</td>
	</tr>
	<tr>
		<th align="left">Partitions</th>
		<td align="center"><code>sde1</code></td>
		<td align="center"><code>sdf1</code></td>
		<td align="center"><code>sdg1</code></td>
		<td align="center"><code>sdh1</code></td>
		<td align="center"><code>sdi1</code></td>
		<td align="center"><code>sde2</code></td>
		<td align="center"><code>sdf2</code></td>
	</tr>
	<tr>
		<th align="left">Drives</th>
		<td align="center"><code>sde</code></td>
		<td align="center"><code>sdf</code></td>
		<td align="center"><code>sdg</code></td>
		<td align="center"><code>sdh</code></td>
		<td align="center"><code>sdi</code></td>
		<td align="center"><code>sde</code></td>
		<td align="center"><code>sdf</code></td>
	</tr>
	<tr>
		<th align="left">MBR</th>
		<td align="center">yes</td>
		<td align="center">yes</td>
		<td align="center"></td>
		<td align="center"></td>
		<td align="center"></td>
		<td align="center"></td>
		<td align="center"></td>
	</tr>
</table>

### Caching

#### Basic caching
Bootable system, caching also accelerates booting.
<table align="center">
	<tr>
		<th align="left">File systems</th>
		<td align="center">ext4</td>
		<td align="center">swap</td>
	</tr>
	<tr>
		<th align="left">Subvolumes</th>
		<td align="center"></td>
		<td align="center"></td>
	</tr>
	<tr>
		<th align="left">Mount points</th>
		<td align="center"><code>/</code></td>
		<td align="center"></td>
	</tr>
	<tr>
		<th align="left">LUKS encryption</th>
		<td align="center"></td>
		<td align="center"></td>
	</tr>
	<tr>
		<th align="left">Cache</th>
		<td align="center"><code>sde1</code><br>(SSD <code>sde</code>)</td>
		<td align="center"></td>
	</tr>
	<tr>
		<th align="left">RAID arrays</th>
		<td align="center"></td>
		<td align="center"></td>
	</tr>
	<tr>
		<th align="left">Partitions</th>
		<td align="center"><code>sdf1</code></td>
		<td align="center"><code>sdf2</code></td>
	</tr>
	<tr>
		<th align="left">Drives</th>
		<td align="center" colspan="2"><code>sdf</code></td>
	</tr>
	<tr>
		<th align="left">MBR</th>
		<td align="center" colspan="2">yes</td>
	</tr>
</table>

#### Caching a (slow) encrypted RAID6
... as could be found in a NAS.
<table align="center">
	<tr>
		<th align="left">File systems</th>
		<td align="center" colspan="4">btrfs</td>
	</tr>
	<tr>
		<th align="left">Subvolumes</th>
		<td align="center" colspan="2"><code>@</code></td>
		<td align="center" colspan="2"><code>@media</code></td>
	</tr>
	<tr>
		<th align="left">Mount points</th>
		<td align="center" colspan="2"><code>/</code></td>
		<td align="center" colspan="2"><code>/media</code></td>
	</tr>
	<tr>
		<th align="left">LUKS encryption</th>
		<td align="center" colspan="4">yes</td>
	</tr>
	<tr>
		<th align="left">Cache</th>
		<td align="center" colspan="4"><code>sde1</code><br>(SSD <code>sde</code>)</td>
	</tr>
	<tr>
		<th align="left">RAID arrays</th>
		<td align="center" colspan="4">RAID6</td>
	</tr>
	<tr>
		<th align="left">Partitions</th>
		<td align="center"><code>sdf1</code></td>
		<td align="center"><code>sdg1</code></td>
		<td align="center"><code>sdh1</code></td>
		<td align="center"><code>sdi1</code></td>
	</tr>
	<tr>
		<th align="left">Drives</th>
		<td align="center"><code>sdf</code></td>
		<td align="center"><code>sdg</code></td>
		<td align="center"><code>sdh</code></td>
		<td align="center"><code>sdi</code></td>
	</tr>
	<tr>
		<th align="left">MBR</th>
		<td align="center" colspan="4"></td>
	</tr>
</table>

#### Caching multiple encrypted file systems on the same SSD
Boots from an SSD partition and uses another SSD partition of the same device
as cache.
<table align="center">
	<tr>
		<th align="left">File systems</th>
		<td align="center">ext2</td>
		<td align="center">ext4</td>
		<td align="center" colspan="2">btrfs</td>
	</tr>
	<tr>
		<th align="left">Subvolumes</th>
		<td align="center"></td>
		<td align="center"></td>
		<td align="center"><code>@home</code></td>
		<td align="center"><code>@var</code></td>
	</tr>
	<tr>
		<th align="left">Mount points</th>
		<td align="center"><code>/boot</code></td>
		<td align="center"><code>/</code></td>
		<td align="center"><code>/home</code></td>
		<td align="center"><code>/var</code></td>
	</tr>
	<tr>
		<th align="left">LUKS encryption</th>
		<td align="center"></td>
		<td align="center">yes</td>
		<td align="center" colspan="2">yes</td>
	</tr>
	<tr>
		<th align="left">Cache</th>
		<td align="center"></td>
		<td align="center" colspan="3"><code>sde1</code><br>(SSD <code>sde</code>)</td>
	</tr>
	<tr>
		<th align="left">RAID arrays</th>
		<td align="center"></td>
		<td align="center"></td>
		<td align="center" colspan="2">RAID1</td>
	</tr>
	<tr>
		<th align="left">Partitions</th>
		<td align="center"><code>sde2</code></td>
		<td align="center"><code>sdf1</code></td>
		<td align="center"><code>sdg1</code></td>
		<td align="center"><code>sdh1</code></td>
	</tr>
	<tr>
		<th align="left">Drives</th>
		<td align="center"><code>sde</code><br>(SSD)</td>
		<td align="center"><code>sdf</code></td>
		<td align="center"><code>sdg</code></td>
		<td align="center"><code>sdh</code></td>
	</tr>
	<tr>
		<th align="left">MBR</th>
		<td align="center">yes</td>
		<td align="center"></td>
		<td align="center"></td>
		<td align="center"></td>
	</tr>
</table>

## FAQ

- [Which Ubuntu hosts are supported?](#which-ubuntu-hosts-are-supported)
- [What about Debian hosts and targets?](#what-about-debian-hosts-and-targets)
- [Why use an external tool for partitioning?](#why-use-an-external-tool-for-partitioning)
- [How to install a complete Ubuntu desktop with StorageComposer?](#how-to-install-a-complete-ubuntu-desktop-with-storagecomposer)
- [Which file systems can be created?](#which-file-systems-can-be-created)
- [What does “SSD erase block size” mean and why should I care?](#what-does-ssd-erase-block-size-mean-and-why-should-i-care)
- [Can I create a “fully encrypted” target system?](#can-i-create-a-fully-encrypted-target-system)
- [Do I have to retype my passphrase for each encrypted file system during booting?](#do-i-have-to-retype-my-passphrase-for-each-encrypted-file-system-during-booting)
- [How to avoid retyping my passphrase if `/boot` is encrypted?](#how-to-avoid-retyping-my-passphrase-if-boot-is-encrypted)
- [How to achieve two-factor authentication for encrypted file systems?](#how-to-achieve-two-factor-authentication-for-encrypted-file-systems)
- [Is two-factor authentication possible if `/boot` is encrypted?](#is-two-factor-authentication-possible-if-boot-is-encrypted)
- [To which drives is the MBR written?](#to-which-drives-is-the-mbr-written)
- [Which packages can be affected by cloning?](#which-packages-can-be-affected-by-cloning)
- [Why does StorageComposer sometimes appears to hang when run again shortly after creating a target with MD/RAID?](#why-does-storagecomposer-sometimes-appears-to-hang-when-run-again-shortly-after-creating-a-target-with-md-raid)
- [Does StorageComposer alter the host system on which it is run?](#does-storagecomposer-alter-the-host-system-on-which-it-is-run)
- [What if drive names change between successive runs of StorageComposer?](#what-if-drive-names-change-between-successive-runs-of-storagecomposer)
- [How to deal with “Device is mounted or has a holder or is unknown”?](#how-to-deal-with-device-is-mounted-or-has-a-holder-or-is-unknown)
- [Pressing Ctrl-C at an input prompt leaves my Ubuntu terminal in a mess](#pressing-ctrl-c-at-an-input-prompt-leaves-my-ubuntu-terminal-in-a-mess)

#### Which Ubuntu hosts are supported?
Xenial or later is strongly recommended as the host system. Some packages may
behave differently or may not work properly at all in earlier versions. 

#### What about Debian hosts and targets?
Although it should not be too hard to adapt the scripts to Debian (jessie), this
is still on the wish list.

#### Why use an external tool for partitioning?
Partitioning tools for Linux are readily available, such as `fdisk`, `gdisk`, `parted`, `GParted` and `QtParted`. Attempting to duplicate their
functions in StorageComposer did not appear worthwhile.

#### How to install a complete Ubuntu desktop with StorageComposer?
Unfortunalety, I could not make the Ubuntu Live DVD installer work with encrypted and
cached partitions created by StorageComposer.

Therefore, let StorageComposer install a basic Ubuntu on your target system first.
Then `chroot` into your target or boot it and install one of these packages:
`{ed,k,l,q,x,}ubuntu-desktop`. The result is similar but not identical
to what the Ubuntu installer produces. Most notably, you will have to install
localization packages such as `language-pack-*` by hand.

#### Which file systems can be created?
Currently [ext2, ext3, ext4](https://ext4.wiki.kernel.org/index.php/Main_Page),
[btrfs](https://btrfs.wiki.kernel.org/index.php/Main_Page), 
[xfs](http://xfs.org/index.php/Main_Page) and swap space.

#### What does “SSD erase block size” mean and why should I care?
An “erase block” is the smallest unit that a NAND flash can erase (cited from
[this article](https://wiki.linaro.org/WorkingGroups/KernelArchived/Projects/FlashCardSurvey#Erase_blocks_and_GC_Units)).
The SSD cache ([bcache](https://bcache.evilpiepirate.org/)) allocates SSD space
in erase block-sized chunks in order to optimize performance. However, whether
or not alignment with erase block size actually affects SSD performance seems
unclear as indicated by controversial blogs in the
[references](#references-and-credits). 

#### Can I create a “fully encrypted” target system?
Yes, if the target system is not bootable and is used only for _storage_, e.g. for
backups or for media. 

If the target is bootable then the MBR and the boot partition remain unencrypted 
which makes them vulnerable to
[“evil maid” attacks](https://www.schneier.com/blog/archives/2009/10/evil_maid_attac.html).
A tool like [chkboot](https://github.com/inhies/chkboot#introduction)
could be used to detect whether MBR or boot partition have been tampered with,
but unfortunately only _after_ the malware had an opportunity to run. Please note
that such systems are frequently called “fully encrypted” although they are not.

#### Do I have to retype my passphrase for each encrypted file system during booting?
If `/boot` is not on an encrypted file system then you need to enter
your passphrase only once. The LUKS passphrase is derived
from it according to the selected [LUKS authorization method](#authorization)
and saved in the kernel keyring for all your encrypted file systems. The saved
LUKS passphrase is discarded after 60&nbsp;seconds; by that time, all encrypted file
systems should be open.

On the other hand, if `/boot` is on an encrypted file system then your 
passphrase is requested twice: first for `/boot` by GRUB2 and then for the
actual file system(s) by the initramfs. This is true even if there is only a
(single) root filesystem. An additional inconvenience is that the keyboard
is in US layout for the first passphrase and in localized layout for the second
one. Although
[localized keyboards are possible in GRUB2](http://askubuntu.com/questions/751259/how-to-change-grub-command-line-grub-shell-keyboard-layout#751260),
the process is cumbersome and the result is less-than-perfect.

Please note also that there is not so much security to gain from an encrypted `/boot`
file system; even then, the MBR remains unencrypted and is still vulnerable to
[“evil maid” attacks](https://www.schneier.com/blog/archives/2009/10/evil_maid_attac.html).

#### How to avoid retyping my passphrase if `/boot` is encrypted?
Make a separate file system for `/boot` (e.g. ext2) on a LUKS-encrypted 
partition, using your passphrase.
Encrypt the remaining file systems with a key file. Save the key file in the
initramfs in `/boot`.  
StorageComposer cannot do all of this, some manual work is required.

#### How to achieve two-factor authentication for encrypted file systems?
Use a key file for [LUKS authorization](#authorization) (method&nbsp;2 or&nbsp;3)
and keep it on a removable device (USB stick, MMC card).

#### Is two-factor authentication possible if `/boot` is encrypted?
Yes, the solution is similar to
[How to avoid retyping my passphrase if `/boot` is encrypted?](#how-to-avoid-retyping-my-passphrase-if-boot-is-encrypted)
Just create your `/boot` file system on a LUKS-encrypted partition of a removable
drive.

#### To which drives is the MBR written?
If the storage is made bootable then an MBR is written to all target drives
making up the file system mounted at `/boot` if such a file system exists.
Otherwise, the MBR goes to all target drives of the root file system.

#### Which packages can be affected by cloning?
File systems, caches etc. that are unsupported by StorageComposer can never be part
of the target storage configuration. Therefore, the following packages are purged
from the target in order to get rid of their effects on initramfs, `systemd`
services, `udev` rules etc.:
`f2fs-tools`, `nilfs-tools`, `jfsutils`, `reiserfsprogs`, `ocfs2-*`,
`zfs-*`, `cachefilesd`, `flashcache-*`, `lvm2`.

Packages from the source that are also required by the target are reconfigured from 
scratch, i.e. they are purged and reinstalled only if needed: 
`mdadm`, `bcache-tools`, `cryptsetup`, `btrfs-tools`, `xfsprogs`.

#### Why does StorageComposer sometimes appears to hang when run again shortly after creating a target with MD/RAID?
Immediately after being created, the RAID starts an initial resync. During that
time, RAID performance is quite low, notably for RAID5 and RAID6. Since 
StorageComposer queries all block devices (including RAIDs) repeatedly, this
may cause a long delay until the initial `Configuration summary` or a 
response appear at the console.

#### Does StorageComposer alter the host system on which it is run?
StorageComposer may change system settings temporarily while it is running
and restores them when it terminates.
 
Depending on your storage configuration, one or more of these packages
will be installed permanently (unless already present):
`mdadm`, `smartmontools`, `cryptsetup`, `keyutils`, `gnupg`, `whois`,
`bcache-tools`, `btrfs-tools`, `xfsprogs`, `fio`, `debconf-utils`,
`openssh-client` and `debootstrap`.

Some packages copy files to your initramfs, install `systemd` services, add
`udev` rules etc. Thus, additional block devices (notably RAID, LUKS and
caching devices) may show up in your system. The `lsblk`command provides an
overview.

Drive error and driver timeouts of the RAID components for your storage are
adjusted on the host system and also on the bootable system. For details, see
[this blog](http://strugglers.net/~andy/blog/2015/11/09/linux-software-raid-and-drive-timeouts/),
[this bug report](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=780162)
and [this bug report](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=780207).
Running <code>dmesg&nbsp;|&nbsp;grep&nbsp;mdraid-helper</code> shows what was changed.
Changes on the host system persist until shutdown or hibernation.   

#### What if drive names change between successive runs of StorageComposer?
On reboot, drives and partitions may be assigned differing names, e.g.
`/dev/sdd2` may become `/dev/sde2`etc. This does not
affect StorageComposer as it identifies partitions by UUID in the
<code>&lt;config&#x2011;file&gt;</code>. Partition names in the user interface are
looked up by UUID and adapt automatically to the current drive naming scheme
of your system.

#### How to deal with “Device is mounted or has a holder or is unknown”?
Apart from the obvious (unknown device), this error message may appear if your
build/mount configuration contains a device which is a currently active MD/RAID
or bcache component (eventually as the result of a previous run of 
StorageComposer).

First, verify that the device in question __does not belong to your host system__
and find out where it is mounted, if at all.
Then run `sudo stcomp.sh -u` with a new configuration file. Specify that device
for the root file system (no caching, no encryption, any file system type) and
enter the proper mount point (or any empty directory). This will unlock the device.
Hopefully. Syncing MD/RAIDs can be stubborn.

#### Pressing Ctrl-C at an input prompt leaves my Ubuntu terminal in a mess
Unfortunately, this is a
[known bug](https://lists.gnu.org/archive/html/bug-bash/2014-09/msg00029.html)
in bash. Apparently, the patch did not yet make it into your Ubuntu distribution.  

## Missing features
- GPT/UEFI support
- Debian support
- Producing _exactly_ the same result as the Ubuntu/Xubuntu/Kubuntu Live DVD installers
- Friendly user interface, possibly using Python+PySide or Qt

## Licenses
StorageComposer is licensed under the
[GPL 3.0](https://www.gnu.org/licenses/gpl-3.0.en.html).
This document is licensed under the Creative Commons license
[CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/us/).

## References and credits
Credits go to the authors and contributors of these documents:

1. [_Ext4 (and Ext2/Ext3) Wiki_](https://ext4.wiki.kernel.org/index.php/Main_Page).
   kernel.org Wiki, 2016-09-20. Retrieved 2016-10-14.
   
1. [_btrfs Wiki_](https://btrfs.wiki.kernel.org/index.php/Main_Page).
   kernel.org Wiki, 2016-10-13. Retrieved 2016-10-14.
   
1. [_XFS_](http://xfs.org/index.php/Main_Page).
   XFS.org Wiki, 2016-06-06. Retrieved 2016-10-14.

1. Tridgell, Andrew; Mackerras, Paul et al.:
   [_rsync manpage_](http://manpages.ubuntu.com/manpages/xenial/en/man1/rsync.1.html).
   Ubuntu Manpage Repository, 2014-06-22. Retrieved 2016-10-23.

1. [_SSH_](https://help.ubuntu.com/community/SSH).
   Ubuntu Community Help Wiki, 2015-02-27. Retrieved 2016-10-28.
   
1. [_Linux Raid Wiki_](https://raid.wiki.kernel.org/index.php/Linux_Raid).
   kernel.org Wiki, 2016-10-12. Retrieved 2016-10-14.

1. Smith, Andy:
   [_Linux Software RAID and drive timeouts_](http://strugglers.net/~andy/blog/2015/11/09/linux-software-raid-and-drive-timeouts/).
   The ongoing struggle (blog), 2015-11-09. Retrieved 2016-10-14.
   
1. [_General debian base-system fix: default HDD timeouts cause data loss or corruption (silent controller resets)_](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=780162).
   Debian Bug report #780162, 2015-03-09. Retrieved 2016-10-14.
   
1. [_Default HDD block error correction timeouts: make entire! drives fail + high risk of data loss during array re-build_](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=780207).
   Debian Bug report #780162, 2015-03-10. Retrieved 2016-10-14.

1. Rath, Nikolaus:
   [_SSD Caching under Linux_](https://www.rath.org/ssd-caching-under-linux.html).
   Nikolaus Rath's Website (blog), 2016-02-10. Retrieved 2016-10-18.
   
1. Overstreet, Kent:
   [_What is bcache?_](https://bcache.evilpiepirate.org/#index2h1)
   evilpiepirate.org, 2016-08-28. Retrieved 2016-10-14.
   
1. [_Flash memory card design_](https://wiki.linaro.org/WorkingGroups/KernelArchived/Projects/FlashCardSurvey). Linaro.org Wiki, 2013-02-18.
   Retrieved 2016-10-14.
   
1. Smith, Roderick W.:
   [_Linux on 4 KB sector disks: Practical advice_](https://www.ibm.com/developerworks/linux/library/l-linux-on-4kb-sector-disks/).
   IBM developerWorks, 2014-03-06. Retrieved 2016-10-13.
   
1. Bergmann, Arnd:
   [_Optimizing Linux with cheap flash drives_](http://lwn.net/Articles/428584/).
   LWN.net, 2011-02-18. Retrieved 2016-10-13.

1. [_M550 Erase Block Size_](http://forum.crucial.com/t5/Crucial-SSDs/M550-Erase-Block-Size/td-p/155238).
   Crucial community forum, 2014-07-18. Retrieved 2016-10-13.

1. [_dm-crypt_](https://en.wikipedia.org/wiki/Dm-crypt).
   Wikipedia, 2016-10-10. Retrieved 2016-10-14.
   
1. [_LUKS_](https://en.wikipedia.org/wiki/Linux_Unified_Key_Setup).
   Wikipedia, 2016-05-16. Retrieved 2016-10-14.
   
1. Saout, Jana; Frühwirth, Clemens; Broz, Milan; Wagner, Arno:
   [_cryptsetup manpage_](http://manpages.ubuntu.com/manpages/xenial/man8/cryptsetup.8.html).
   Ubuntu Manpage Repository, 2016-04-21. Retrieved 2016-10-14.
   
1. Ashley, Mike; Copeland, Matthew; Grahn, Joergen; Wheeler, David A.:
   [_The GNU Privacy Handbook: Encrypting and decrypting documents_](https://www.gnupg.org/gph/en/manual.html).
   The Free Software Foundation, 1999. Retrieved 2016-10-14.
   
1. [_Multi-factor authentication_](https://en.wikipedia.org/wiki/Multi-factor_authentication).
   Wikipedia, 2016-10-12. Retrieved 2016-10-14.
   
1. Zak, Karel:
   [_mount manpage_](http://manpages.ubuntu.com/manpages/xenial/man8/mount.8.html).
   Ubuntu Manpage Repository, 2016-04-21. Retrieved 2016-10-22.
   
1. Axboe, Jens:
   [_fio HOWTO_](https://github.com/axboe/fio/blob/master/HOWTO).
   GitHub, 2016-10-18. Retrieved 2016-10-14.

1. Carroll, Aaron; Axboe, Jens:
   [_fio manpage_](http://manpages.ubuntu.com/manpages/xenial/en/man1/fio.1.html).
   Ubuntu Manpage Repository, 2016-04-21. Retrieved 2016-10-23.
   
1. Schneier, Bruce:
   [_“Evil Maid” Attacks on Encrypted Hard Drives_](https://www.schneier.com/blog/archives/2009/10/evil_maid_attac.html).
   Schneier on Security, 2009-10-23. Retrieved 2016-10-14.

1. Schmidt, Jürgen et al.:
   [_chkboot_](https://github.com/inhies/chkboot).
   Github, 2014-01-07. Retrieved 2016-10-14.
   
1. KrisWebDev:
   [_How to change grub command-line (grub shell) keyboard layout?_](http://askubuntu.com/questions/751259/how-to-change-grub-command-line-grub-shell-keyboard-layout#751260)
   Ask Ubuntu (forum), 2016-03-28. Retrieved 2016-10-14.

1. Thomas, Mickaël:
   [_read -e does not restore terminal settings correctly when interrupted if a trap is set_](https://lists.gnu.org/archive/html/bug-bash/2014-09/msg00029.html).
   bug-bash Archives, 2014-09-08. Retrieved 2016-10-19.
