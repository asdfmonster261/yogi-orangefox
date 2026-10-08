from patch import BaseSubPatch


class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "recovery: ignore data wipes requested by Android"
        self.target_file = "bootable/recovery/startupArgs.cpp"

        self.CHANGES = [
            (
                r"""
		} else if (args[index].find(WIPE_DATA) != std::string::npos) {
			#ifdef OF_VAB_ORS_WIPE_DATA_IS_FORMAT
				LOGINFO("Received OpenRecovery 'wipe data' command; converting to 'format data'\n");
				if (!OpenRecoveryScript::Insert_ORS_Command("format data\n"))
			#else
				LOGINFO("Received OpenRecovery 'wipe data' command.\n");
				if (!OpenRecoveryScript::Insert_ORS_Command("wipe data\n"))
			#endif
				return false;
		} else if (args[index].find(WIPE_CACHE) != std::string::npos) {
""",
                r"""
		} else if (args[index].find(WIPE_DATA) != std::string::npos) {
			// Android asked for a data wipe: Erase all data in Settings, a device admin, an
			// update, or init after a failed boot. A wipe is never carried out from the boot
			// message; someone at the phone has to start it.
			LOGINFO("Ignoring a data wipe requested by Android\n");
		} else if (args[index].find(WIPE_CACHE) != std::string::npos) {
"""
            ),
        ]
