from patch import BaseSubPatch


class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "recovery: format /data the way the stock factory reset does"
        self.target_file = "bootable/recovery/partitionmanager.cpp"

        self.CHANGES = [
            (
                r"""
#include <libsnapshot/snapshot.h>
#include <private/android_filesystem_config.h> /* for AID_SYSTEM */
""",
                r"""
#include <libsnapshot/snapshot.h>
#include <private/android_filesystem_config.h> /* for AID_SYSTEM */
#include <algorithm>
#include <android-base/unique_fd.h>
#include <bootloader_message/bootloader_message.h>
#include <sys/ioctl.h>
"""
            ),
            (
                r"""
int TWPartitionManager::Format_Data(void) {
	if (TWFunc::Block_Operations_Until_Reboot())
		return false;
	TWPartition* dat = Find_Partition_By_Path("/data");
	TWPartition* metadata = Find_Partition_By_Path("/metadata");
	bool ret = false;
	if (metadata != NULL)
		metadata->UnMount(false);

	if (dat != NULL) {
		#ifdef OF_REFRESH_ENCRYPTION_PROPS_BEFORE_FORMAT
		Update_Encryption_Props_Before_Format(); // call here, because it must run before Unmap_Super_Devices is executed
		#endif
		if (android::base::GetBoolProperty("ro.virtual_ab.enabled", false)) {
#ifndef TW_EXCLUDE_APEX
			twrpApex apex;
			apex.Unmount();
#endif
			if (metadata != NULL)
				metadata->Mount(true);
			if (!Check_Pending_Merges())
				return false;
		}
		ret = dat->Wipe_Encryption();
	} else {
		gui_msg(Msg(msg::kError, "unable_to_locate=Unable to locate {1}.")("/data"));
		return false;
	}

	if (ret) {
		#ifdef OF_WIPE_METADATA_AFTER_DATAFORMAT
		usleep(2048);
		Wipe_By_Path("/metadata");
		usleep(2048);
		#endif
		TWFunc::check_and_run_script(TW_FORMAT_DATA_SCRIPT, "Format Data Script");
	}
	return ret;
}
""",
                r"""
// Format Data follows the stock recovery's factory reset. /data itself is never
// formatted here: once the start of userdata is blank, Android's vold formats every
// device of the multi-device /data on the next boot, as it does after a stock reset.
namespace {

// fs_mgr decides that /data was wiped from its first 4 KiB alone.
constexpr size_t kWipedCheckSize = 4096;

// Unmounts every mount of /data's file system and everything below /data and
// /sdcard, children first. Never lazily: a detached f2fs can write its superblock
// back after the discard, and Android would then not see userdata as wiped.
bool UnmountDataMounts() {
	// Not /proc/mounts: it is a symlink, which ReadFileToString won't follow.
	std::string text;
	if (!android::base::ReadFileToString("/proc/self/mounts", &text)) {
		LOGERR("Unable to read /proc/self/mounts\n");
		return false;
	}
	std::vector<std::pair<std::string, std::string>> mounts;
	std::string data_source;
	for (const auto& line : android::base::Split(text, "\n")) {
		const std::vector<std::string> fields = android::base::Split(line, " ");
		if (fields.size() < 2)
			continue;
		mounts.emplace_back(fields[0], fields[1]);
		if (fields[1] == "/data")
			data_source = fields[0];
	}

	std::vector<std::string> targets;
	for (const auto& mount : mounts) {
		const std::string& dir = mount.second;
		if ((!data_source.empty() && mount.first == data_source) || dir == "/data" ||
				android::base::StartsWith(dir, "/data/") || dir == "/sdcard" ||
				android::base::StartsWith(dir, "/sdcard/"))
			targets.push_back(dir);
	}
	std::sort(targets.begin(), targets.end(),
			[](const std::string& a, const std::string& b) { return a.size() > b.size(); });
	for (const auto& dir : targets) {
		if (umount2(dir.c_str(), 0) != 0 && errno != EINVAL && errno != ENOENT) {
			gui_print_color("error", "%s is still in use (%s). Close whatever is using it and try again.\n",
					dir.c_str(), strerror(errno));
			return false;
		}
	}
	return true;
}

// Removes the crypto mappings vold made for /data: userdata and the zoned and
// expansion devices it spans. This also fails if anything still holds them open.
bool RemoveDataMappings() {
	std::vector<std::string> names = {"userdata"};
	if (DIR* dir = opendir("/dev/block/mapper")) {
		while (const dirent* entry = readdir(dir)) {
			const std::string name = entry->d_name;
			if (name == "zoned_device" || android::base::StartsWith(name, "userdata_exp."))
				names.push_back(name);
		}
		closedir(dir);
	}
	for (const auto& name : names) {
		if (access(("/dev/block/mapper/" + name).c_str(), F_OK) != 0)
			continue;
		if (!DestroyLogicalPartition(name)) {
			gui_print_color("error", "Unable to remove the %s mapping; /data may still be in use.\n",
					name.c_str());
			return false;
		}
	}
	return true;
}

// wipe_block_device's discard: a secure discard, or a plain one with the first 4 KiB
// zeroed when the device can't do that.
bool DiscardBlockDevice(int fd, uint64_t size) {
	uint64_t range[2] = {0, size};
	if (ioctl(fd, BLKSECDISCARD, &range) == 0)
		return true;
	range[0] = 0;
	range[1] = size;
	if (ioctl(fd, BLKDISCARD, &range) != 0)
		return false;
	LOGINFO("Secure discard failed, used discard instead\n");
	const std::vector<char> zeros(kWipedCheckSize, 0);
	return android::base::WriteFullyAtOffset(fd, zeros.data(), zeros.size(), 0) && fsync(fd) == 0;
}

// Stock's EraseVolume for a metadata-encrypted /data. Returns false if the discard
// never happened. The first 4 KiB is also zeroed and read back past the page cache,
// since a secure discard doesn't promise zeros; *blank says whether that held.
bool EraseUserdata(const std::string& device, bool* blank) {
	*blank = false;
	std::string path;
	struct stat st, userdata;
	// Only ever the userdata partition itself, whatever the fstab says.
	if (!android::base::Realpath(device, &path) || stat(path.c_str(), &st) != 0 ||
			!S_ISBLK(st.st_mode) || android::base::StartsWith(path, "/dev/block/dm-") ||
			stat("/dev/block/by-name/userdata", &userdata) != 0 || !S_ISBLK(userdata.st_mode) ||
			st.st_rdev != userdata.st_rdev) {
		gui_print_color("error", "%s is not the raw userdata device. Nothing was erased.\n",
				device.c_str());
		return false;
	}
	android::base::unique_fd fd(open(path.c_str(), O_RDWR | O_CLOEXEC));
	uint64_t size = 0;
	if (fd.get() < 0 || ioctl(fd.get(), BLKGETSIZE64, &size) != 0 || size < kWipedCheckSize) {
		gui_print_color("error", "Unable to open %s. Nothing was erased.\n", path.c_str());
		return false;
	}
	if (!DiscardBlockDevice(fd.get(), size)) {
		gui_print_color("error", "Unable to discard %s.\n", path.c_str());
		return false;
	}

	const std::vector<char> zeros(kWipedCheckSize, 0);
	if (!android::base::WriteFullyAtOffset(fd.get(), zeros.data(), zeros.size(), 0) ||
			fsync(fd.get()) != 0)
		return true;
	android::base::unique_fd direct(open(path.c_str(), O_RDONLY | O_DIRECT | O_CLOEXEC));
	void* buf = nullptr;
	if (direct.get() < 0 || posix_memalign(&buf, kWipedCheckSize, kWipedCheckSize) != 0)
		return true;
	const uint8_t* bytes = static_cast<const uint8_t*>(buf);
	*blank = android::base::ReadFullyAtOffset(direct.get(), buf, kWipedCheckSize, 0) &&
			std::all_of(bytes, bytes + kWipedCheckSize, [](uint8_t b) { return b == 0; });
	free(buf);
	return true;
}

// /dev/gsc0 opens once at a time, so recovery_weaver is stopped first. It isn't
// started again: the wipe takes the Weaver slots it serves with it.
bool WipeTitanM() {
	const std::string state = android::base::GetProperty("init.svc.recovery_weaver", "");
	if (state == "running" || state == "restarting") {
		android::base::SetProperty("ctl.stop", "recovery_weaver");
		if (!android::base::WaitForProperty("init.svc.recovery_weaver", "stopped",
				std::chrono::seconds(5)))
			LOGINFO("recovery_weaver did not stop\n");
	}
	std::string output;
	const int ret = TWFunc::Exec_Cmd("/system/bin/titan_wipe --erase", output, true);
	LOGINFO("%s", output.c_str());
	return ret == 0;
}

bool WipeTrustyUserdata() {
	const char* path = "/dev/block/by-name/trusty_userdata";
	android::base::unique_fd fd(open(path, O_WRONLY | O_CLOEXEC));
	if (fd.get() < 0) {
		if (errno == ENOENT) {
			LOGINFO("%s does not exist, skip wiping trusty_userdata\n", path);
			return true;
		}
		LOGERR("Failed to open %s: %s\n", path, strerror(errno));
		return false;
	}
	uint64_t size = 0;
	if (ioctl(fd.get(), BLKGETSIZE64, &size) != 0 || !DiscardBlockDevice(fd.get(), size)) {
		LOGERR("Failed to wipe %s: %s\n", path, strerror(errno));
		return false;
	}
	LOGINFO("Wiped Trusty user data successfully\n");
	return true;
}

// The two Pixel bootloader flags in misc that the stock wipe clears: the dark theme
// (10 bytes, "theme-dark", at the start of the vendor space) and the preferred display
// mode (32 bytes at 456).
bool ClearMiscFlags() {
	std::string err;
	const std::string misc = get_misc_blk_device(&err);
	if (misc.empty()) {
		LOGERR("Unable to find misc: %s\n", err.c_str());
		return false;
	}
	const char theme[10] = {};
	const char display_mode[32] = {};
	bool ok = true;
	if (!write_misc_partition(theme, sizeof(theme), misc, VENDOR_SPACE_OFFSET_IN_MISC, &err)) {
		LOGERR("Failed to clear the dark theme flag: %s\n", err.c_str());
		ok = false;
	}
	if (!write_misc_partition(display_mode, sizeof(display_mode), misc,
			VENDOR_SPACE_OFFSET_IN_MISC + 456, &err)) {
		LOGERR("Failed to clear the user preferred resolution: %s\n", err.c_str());
		ok = false;
	}
	return ok;
}

}  // namespace

int TWPartitionManager::Format_Data(void) {
	if (TWFunc::Block_Operations_Until_Reboot())
		return false;
	TWPartition* dat = Find_Partition_By_Path("/data");
	TWPartition* metadata = Find_Partition_By_Path("/metadata");
	if (dat == NULL || metadata == NULL) {
		gui_msg(Msg(msg::kError, "unable_to_locate=Unable to locate {1}.")(dat == NULL ? "/data" : "/metadata"));
		return false;
	}

	gui_print("Unmounting /data...\n");
	Disable_MTP();
	if (!UnmountDataMounts() || !RemoveDataMappings())
		return false;

	metadata->UnMount(false);
	#ifdef OF_REFRESH_ENCRYPTION_PROPS_BEFORE_FORMAT
	Update_Encryption_Props_Before_Format(); // call here, because it must run before Unmap_Super_Devices is executed
	#endif
	if (android::base::GetBoolProperty("ro.virtual_ab.enabled", false)) {
#ifndef TW_EXCLUDE_APEX
		twrpApex apex;
		apex.Unmount();
#endif
		// As stock does, finish or cancel a pending update's merge before the wipe.
		metadata->Mount(true);
		if (!Check_Pending_Merges())
			return false;
	}
	// /metadata is formatted after the point of no return, so make sure it can be.
	if (!metadata->UnMount(true))
		return false;

	gui_print("Erasing /data...\n");
	bool blank = false;
	if (!EraseUserdata(dat->Primary_Block_Device, &blank))
		return false;
	// Nothing below can be undone, so every step runs and failures are reported at the
	// end, as stock does.
	dat->Can_Be_Mounted = false;
	bool success = blank;
	if (!blank)
		gui_print_color("error", "The start of userdata did not read back blank, so Android may not set up /data.\n");

	gui_print("Formatting /metadata...\n");
	if (!Wipe_By_Path("/metadata"))
		success = false;

	std::string err;
	if (!WriteMiscMemtagMessage({}, &err)) {
		LOGERR("Failed to reset the memtag message: %s\n", err.c_str());
		success = false;
	}

	gui_print("Wiping Titan M...\n");
	if (!WipeTitanM())
		success = false;
	if (!WipeTrustyUserdata())
		success = false;
	if (!ClearMiscFlags())
		success = false;

	TWFunc::check_and_run_script(TW_FORMAT_DATA_SCRIPT, "Format Data Script");
	if (success)
		gui_print("Data erased. Android sets up /data on its next boot.\n");
	else
		gui_print_color("warning", "Data erased, but not every step succeeded; see the log.\n");
	return success;
}
"""
            ),
        ]
