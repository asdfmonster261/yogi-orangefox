from patch import BaseSubPatch, Colors


class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "fs_mgr: add FstabEntry.user_devices for expansion devices"
        self.target_file = "system/core/fs_mgr/libfstab/include/fstab/fstab.h"
        self.CHANGES = [
            (
                r"""    std::string blk_device;
    std::string zoned_device;""",
                r"""    std::string blk_device;
    std::string zoned_device;
    std::vector<std::string> user_devices;""",
            ),
        ]
