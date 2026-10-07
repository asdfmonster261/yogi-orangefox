from patch import BaseSubPatch


class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "recovery: warn when /data is in checkpoint mode"
        self.target_file = "bootable/recovery/twrp.cpp"

        self.CHANGES = [
            (
                r"""
#ifndef TW_OEM_BUILD
	// Check if system has never been changed
	TWPartition* sys = PartitionManager.Find_Partition_By_Path(PartitionManager.Get_Android_Root_Path());
""",
                r"""
	// Android commits a pending userdata checkpoint (an OTA's first boot, staged Play
	// system updates) only once it has booted fully. Until then vold mounts /data with
	// checkpoint=disable here too, and f2fs drops everything written in this session
	// at the next mount.
	{
		std::vector<std::string> mounts;
		if (TWFunc::read_file("/proc/mounts", mounts) == 0) {
			for (const std::string& line : mounts) {
				if (line.find(" /data f2fs ") == std::string::npos ||
				    line.find("checkpoint=disable") == std::string::npos)
					continue;
				gui_warn("data_checkpoint=Android has an update to finish. Changes made to Data are lost at reboot until Android has booted once.");
				if (gui_startPage("data_checkpoint", 1, 1) != 0)
					LOGERR("Failed to start data_checkpoint GUI page.\n");
				break;
			}
		}
	}

#ifndef TW_OEM_BUILD
	// Check if system has never been changed
	TWPartition* sys = PartitionManager.Find_Partition_By_Path(PartitionManager.Get_Android_Root_Path());
"""
            ),
        ]
