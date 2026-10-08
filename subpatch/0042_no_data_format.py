from patch import BaseSubPatch


class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "recovery: refuse to mkfs /data"
        self.target_file = "bootable/recovery/partition.cpp"

        # Format Data leaves the format to Android, as the stock factory reset does (0044).
        # These refuse every other path into a /data mkfs: TWRP's own format, a file
        # system change, or a restore made on a different file system. Formatting yogi's
        # zoned, multi-device /data from recovery is suspected in damage to its UFS.
        self.CHANGES = [
            (
                r"""
bool TWPartition::Wipe_Encryption() {
	bool Save_Data_Media = Has_Data_Media;
	bool ret = false;
	std::string the_wipe_fs;

	if (TWFunc::Block_Operations_Until_Reboot())
		return false;
""",
                r"""
bool TWPartition::Wipe_Encryption() {
	bool Save_Data_Media = Has_Data_Media;
	bool ret = false;
	std::string the_wipe_fs;

	if (TWFunc::Block_Operations_Until_Reboot())
		return false;

	if (Mount_Point == "/data") {
		gui_err("format_data_disabled=Formatting /data this way is disabled on this device; use Format Data.");
		return false;
	}
"""
            ),
            (
                r"""
bool TWPartition::Wipe_EXT4() {
#ifdef USE_EXT4
""",
                r"""
bool TWPartition::Wipe_EXT4() {
	if (Mount_Point == "/data") {
		gui_err("format_data_disabled=Formatting /data this way is disabled on this device; use Format Data.");
		return false;
	}
#ifdef USE_EXT4
"""
            ),
            (
                r"""
bool TWPartition::Wipe_F2FS() {
	std::string f2fs_command;

	if (!UnMount(true))
		return false;
""",
                r"""
bool TWPartition::Wipe_F2FS() {
	std::string f2fs_command;

	if (Mount_Point == "/data") {
		gui_err("format_data_disabled=Formatting /data this way is disabled on this device; use Format Data.");
		return false;
	}

	if (!UnMount(true))
		return false;
"""
            ),
        ]
