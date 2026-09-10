from patch import BaseSubPatch, Colors

class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "Pass TW_FRAMERATE to the gui (libguitwrp_defaults.go)"
        self.target_file = "bootable/recovery/gui/libguitwrp_defaults.go"

        # gui.cpp gates the render loop on TW_FRAMERATE, but nothing in the build
        # ever passed the make variable to the compiler, so objects.hpp fell back
        # to its 30 default no matter what a device set. Pass it through.
        self.CHANGES = [
            (
                r"""
	if getMakeVars(ctx, "AB_OTA_UPDATER") == "true" {
		cflags = append(cflags, "-DAB_OTA_UPDATER=1")
	}
	return cflags
}
""",
                r"""
	if getMakeVars(ctx, "AB_OTA_UPDATER") == "true" {
		cflags = append(cflags, "-DAB_OTA_UPDATER=1")
	}

	if tw_framerate := getMakeVars(ctx, "TW_FRAMERATE"); tw_framerate != "" {
		cflags = append(cflags, "-DTW_FRAMERATE="+tw_framerate)
	}

	return cflags
}
"""
            ),
        ]
