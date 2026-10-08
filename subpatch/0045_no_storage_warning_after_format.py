from patch import BaseSubPatch


class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "recovery: no storage warning after Format Data"
        self.target_file = "bootable/recovery/partitionmanager.cpp"

        self.CHANGES = [
            (
                r"""
		if (!FreeStorage->Mount(false)) {
			if (current_storage_path == "/usb_otg")
				LOGINFO("Unable to mount storage ('%s')\n", current_storage_path.c_str());
			else
				gui_msg(Msg(msg::kWarning, "unable_to_mount_storage=Unable to mount storage"));
""",
                r"""
		if (!FreeStorage->Mount(false)) {
			// After Format Data, /data has no file system until Android boots, so its
			// storage is expected to be missing.
			const TWPartition* dat = Find_Partition_By_Path("/data");
			if (current_storage_path == "/usb_otg" || (dat != NULL && !dat->Can_Be_Mounted))
				LOGINFO("Unable to mount storage ('%s')\n", current_storage_path.c_str());
			else
				gui_msg(Msg(msg::kWarning, "unable_to_mount_storage=Unable to mount storage"));
"""
            ),
        ]
