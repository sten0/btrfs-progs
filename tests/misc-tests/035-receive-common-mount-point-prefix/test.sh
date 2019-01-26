#!/bin/bash
# Test that receive determines the correct mount point path when there is
# another mount point that matches the destination's path as a prefix.

source "$TEST_TOP/common"

check_prereq btrfs
check_prereq mkfs.btrfs

setup_root_helper

rm -f dev1 dev2
run_check truncate -s 1G dev1
run_check truncate -s 1G dev2
chmod a+w dev1 dev2

loop1=$(run_check_stdout $SUDO_HELPER losetup --find --show dev1)
loop2=$(run_check_stdout $SUDO_HELPER losetup --find --show dev2)

run_check $SUDO_HELPER "$TOP/mkfs.btrfs" -f "$loop1"
run_check $SUDO_HELPER "$TOP/mkfs.btrfs" -f "$loop2"

run_check $SUDO_HELPER mount "$loop1" "$TEST_MNT"
run_check $SUDO_HELPER mkdir "$TEST_MNT/ddis"
run_check $SUDO_HELPER mkdir "$TEST_MNT/ddis-not-a-mount"
run_check $SUDO_HELPER mount "$loop2" "$TEST_MNT/ddis"

echo "some data" | $SUDO_HELPER tee "$TEST_MNT/ddis/file" > /dev/null

run_check $SUDO_HELPER "$TOP/btrfs" subvolume snapshot -r \
	  "$TEST_MNT/ddis" "$TEST_MNT/ddis/snap"

run_check truncate -s 0 send.data
chmod a+w send.data
run_check $SUDO_HELPER "$TOP/btrfs" send -f send.data "$TEST_MNT/ddis/snap"

# The following receive used to fail because it incorrectly determined the mount
# point of the destination path to be $TEST_MNT/ddis and not $TEST_MNT.
run_check $SUDO_HELPER "$TOP/btrfs" receive -f send.data \
	  "$TEST_MNT/ddis-not-a-mount"

run_check $SUDO_HELPER umount "$TEST_MNT/ddis"
run_check $SUDO_HELPER umount "$TEST_MNT"

# Cleanup loop devices and send data.
run_check $SUDO_HELPER losetup -d "$loop1"
run_check $SUDO_HELPER losetup -d "$loop2"
rm -f dev1 dev2 send.data
