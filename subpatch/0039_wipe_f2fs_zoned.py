from patch import BaseSubPatch, Colors


class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "recovery: format f2fs with the zoned device, so wiping /data works"
        self.target_file = "bootable/recovery/partition.cpp"
        # Wipe_F2FS built "make_f2fs ... <device> <sectors>" and nothing else. On a device
        # whose userdata has a zoned companion LU that cannot work: mkfs.f2fs checks the
        # zoned model of the devices it is given and bails with
        #     Error: zoned block device feature is required
        # unless -m is passed, so formatting /data failed outright and wiping fell over
        # with it.
        #
        # AOSP's own format_f2fs() in system/core/fs_mgr/fs_mgr_format.cpp names the zoned
        # device with -c, adds -m, and drops the sector count, letting mkfs size the
        # filesystem across the set itself. It also passes the block size, which TWRP never
        # did. This mirrors it.
        #
        # The expansion devices in the fstab (device=exp:, device=exp_alias:) are
        # deliberately not passed. AOSP does not pass them either; they are attached later,
        # not at mkfs time, and handing them to -c would build a filesystem spanning devices
        # the kernel does not expect at mount.
        self.CHANGES = [
            (
                r"""	f2fs_command += " " + Actual_Block_Device + " " + dev_sz_str;""",
                r"""	// Block size. AOSP passes this and TWRP did not.
	const std::string blk_sz_str = std::to_string(getpagesize());
	f2fs_command += " -w " + blk_sz_str + " -b " + blk_sz_str;

	// A zoned companion device has to be named, and mkfs refuses without -m. Detected the
	// same way fs_mgr detects the legacy zoned_device flag, so a device without one is
	// unaffected and keeps the sector-count form below.
	std::string zoned_device;
	if (Mount_Point == "/data" && TWFunc::Path_Exists("/dev/block/by-name/zoned_device"))
		zoned_device = "/dev/block/by-name/zoned_device";

	if (!zoned_device.empty())
		f2fs_command += " -c " + zoned_device + " -m " + Actual_Block_Device;
	else
		f2fs_command += " " + Actual_Block_Device + " " + dev_sz_str;""",
            ),
        ]
