from patch import BaseSubPatch


class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "recovery: refuse to format /data"
        self.target_file = "bootable/recovery/partition.cpp"

        # Formatting yogi's zoned, multi-device /data is suspected in damage to its UFS,
        # so it is off. Format Data still opens, and is refused before /data is unmounted
        # or its mappings are torn down. Wiping files (rm -rf) is not affected.
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
		gui_err("format_data_disabled=Formatting /data is disabled on this device.");
		return false;
	}
"""
            ),
            # The same refusal where every other path into mkfs ends: a file system
            # change, or a restore made on a different file system.
            (
                r"""
bool TWPartition::Wipe_EXT4() {
#ifdef USE_EXT4
""",
                r"""
bool TWPartition::Wipe_EXT4() {
	if (Mount_Point == "/data") {
		gui_err("format_data_disabled=Formatting /data is disabled on this device.");
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
		gui_err("format_data_disabled=Formatting /data is disabled on this device.");
		return false;
	}

	if (!UnMount(true))
		return false;
"""
            ),
        ]
