.. BTRFS troubleshooting related pages index

Troubleshooting pages
=====================

System messages printed to the log (dmesg, syslog, journal) have limited space
for description and may need further explanation what needs to be done.

Error: parent transid verify error
----------------------------------

Reason: result of a failed internal consistency check of the filesystem's metadata.
Type: permanent

.. code-block::

   [ 4007.489730] BTRFS error (device vdb): parent transid verify failed on 30736384 wanted 10 found 8

The b-tree nodes are linked together, a block pointer in the parent node
contains target block offset and generation that last changed this block. The
block it points to then upon read verifies that the block address and the
generation matches. This check is done on all tree levels.

The number in **faled on 30736384** is the logical block number, **wanted 10**
is the expected generation number in the parent node, **found 8** is the one
found in the target block.  The number difference between the generation can
give a hint when the problem could have happened, in terms of transaction
commits.

Once the mismatched generations are stored on the device, it's permanent and
cannot be easily recovered, because of information loss. The recovery tool
``btrfs restore`` is able to ignore the errors and attempt to restore the data
but due to the inconsistency in the metadata the data need to be verified by the
user.

The root cause of the error cannot be easily determined, possible reasons are:

* logical bug: filesystem structures haven't been properly updated and stored
* misdirected write: the underlying storage does not store the data to the exact
  address as expected and overwrites some other block
* storage device (hardware or emulated) does not properly flush and persist data
  between transactions so they get mixed up
* lost write without proper error handling: writing the block worked as viewed
  on the filesystem layer, but there was a problem on the lower layers not
  propagated upwards

Error: No space left on device (ENOSPC)
---------------------------------------

Type: transient

Space handling on a COW filesystem is tricky, namely when it's in combination
with delayed allocation, dynamic chunk allocation and parallel data updates.
There are several reasons why the ENOSPC might get reported and there's not just
a single cause and solution. The space reservation algorithms try to fairly
assign the space, fall back to heuristics or block writes until enough data are
persisted and possibly making old copies available.

The most obvious way how to exhaust space is to create a file until the data
chunks are full:

.. code-block::

   $ df -h .
   Filesystem      Size  Used Avail Use% Mounted on
   /dev/sda        4.0G  3.6M  2.0G   1% /mnt/

   $ cat /dev/zero > file
   cat: write error: No space left on device

   $ df -h .
   Filesystem      Size  Used Avail Use% Mounted on
   /dev/sdc        4.0G  2.0G     0 100% /mnt/data250

   $ btrfs fi df .
   Data, single: total=1.98GiB, used=1.98GiB
   System, DUP: total=8.00MiB, used=16.00KiB
   Metadata, DUP: total=1.00GiB, used=2.22MiB
   GlobalReserve, single: total=3.25MiB, used=0.00B

The data chunks have been exhausted, so there's really no space left where to
write. The metadata chunks have space but that can't be used for that purpose.

Metadata space got exhausted
^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Cannot track new data extents, no inline files, no reflinks, no xattrs.
Deletion still works.

Balance does not have enough workspace
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Relocation of block groups requires a temporary work space, ie. area on the
device that's available for the filesystem but without any other existing block
groups. Before balance starts a check is performed to verify the requested
action is possible. If not, ENOSPC is returned.

Error: unable to start balance with target metadata profile
-----------------------------------------------------------

.. code-block::

   unable to start balance with target metadata profile 32

This means that a conversion has been attempted from profile *RAID1* to *dup*
with btrfs-progs earlier than version 4.7. Update and you'll be able to do the
conversion.

Error: balance will reduce metadata integrity
---------------------------------------------

The full message in system log

.. code-block::

   balance will reduce metadata integrity, use force if you want this

This means that conversion will remove a degree of metadata redundancy, for
example when going from profile *RAID1* or *dup* to *single*. The force
parameter to ``btrfs balance start -f`` is needed.

How to clean old super block
----------------------------

The preferred way is to use the ``wipefs`` utility that is part of the
*util-linux* package. Running the command with the device will not destroy
the data, just list the detected filesystems:

.. code-block::

   # wipefs /dev/sda
   offset               type
   ----------------------------------------------------------------
   0x10040              btrfs   [filesystem]
                        UUID:  7760469b-1704-487e-9b96-7d7a57d218a5

Remove the filesystem signature at a given offset or wipe all recognized
signatures on the device:

.. code-block::

   # wipefs -o 0x10040 /dev/sda
   8 bytes [5f 42 48 52 66 53 5f 4d] erased at offset 0x10040 (btrfs)

   # wipefs -a /dev/sda
   8 bytes [5f 42 48 52 66 53 5f 4d] erased at offset 0x10040 (btrfs)

.. note::

   The process is reversible, if the 8 bytes are written back, the device is
   recognized again. See below.

.. note::

   *wipefs* clears only the first super block. If available, the second and
   third copies can be used to resurrect the filesystem.

Stale signature on device
^^^^^^^^^^^^^^^^^^^^^^^^^

Related problem regarding partitioned and unpartitioned device: *Long time ago
I created btrfs on /dev/sda. After some changes btrfs moved to /dev/sda1.*

Use ``wipefs -o 0x10040`` (ie. with the offset of the btrfs signature), it
won't touch the parition table.

Manual deletion of super block signature
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

There are three superblocks: the first one is located at 64KiB, the second one
at 64MiB, the third one at 256GiB. The following lines reset the signature
on all the three copies:


.. code-block::

   # dd if=/dev/zero bs=1 count=8 of=/dev/sda seek=$((64*1024+64))
   # dd if=/dev/zero bs=1 count=8 of=/dev/sda seek=$((64*1024*1024+64))
   # dd if=/dev/zero bs=1 count=8 of=/dev/sda seek=$((256*1024*1024*1024+64))

If you want to restore the super block signatures:

.. code-block::

   # echo "_BHRfS_M" | dd bs=1 count=8 of=/dev/sda seek=$((64*1024+64))
   # echo "_BHRfS_M" | dd bs=1 count=8 of=/dev/sda seek=$((64*1024*1024+64))
   # echo "_BHRfS_M" | dd bs=1 count=8 of=/dev/sda seek=$((256*1024*1024*1024+64))

Generic errors, errno
---------------------

Note there's a established text message for the errors, though they are used in
a broader sense (eg. error mentions a file but it can be relevant for another
structure). The title of each section uses the nonstandard meaning that is
perhaps more suitable for a filesystem.

ENOENT (No such entry)
^^^^^^^^^^^^^^^^^^^^^^

Common error "no such entry", in general it may mean that some structure hasn't
been found, eg. an entry in some in-memory tree.  This becomes a critical
problem when the entry is expected to exist because of consistency of the
structures.

ENOMEM (Not enough memory)
^^^^^^^^^^^^^^^^^^^^^^^^^^

Memory allocation error. In many cases the error is recoverable and the
operation restartable after it's reported to userspace. In critical contexts,
like when a transaction needs to be committed, the error is not recoverable and
leads to flipping the filesystem to read-only. Such cases are rare under normal
conditions. Memory can be artificially limited eg. by cgroups, which may
trigger the condition, which is useful for testing but any real workload should
have resources scaled accordingly.

EINVAL (Invalid argument)
^^^^^^^^^^^^^^^^^^^^^^^^^

This is typically returned from ioctl when a parameter is invalid, ie. unexpected
range, a bit flag not recognized, or a combination of input parameters that
does not make sense. Errors are typically recoverable.

EUCLEAN (Filesystem corrupted)
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

The text of the message is confusing "Structure needs cleaning", in reality this
is used to describe a severe corruption condition. The reason of the corruption
is unknown at this point, but some constraint or condition has been violated
and the filesystem driver can't do much. In practice such errors can be observed
on fuzzed images, faulty hardware or misinteraction with other parts of the
operating system.

EIO (Input/output error)
^^^^^^^^^^^^^^^^^^^^^^^^

"Input output error", typically returned as an error from a device that was
unable to read data, or finish a write. Checksum errors also lead to EIO, there
isn't an established error for checksum validation errors, although some
filesystems use EBADMSG for that.

EEXIST (Object already exists)
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

ENOSPC (No space left)
^^^^^^^^^^^^^^^^^^^^^^

EOPNOTSUPP (Operation not supported)
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^


TODO
----

Transient

- enospc

- operation cannot be done

Possibly both

- checksum errors from changes on the medium under hands

- transient because of direct io

- stored from faulty data in memory
