from patch import BaseSubPatch, Colors


class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "recovery: raise metadata-decrypt timeout for multi-device userdata"
        self.target_file = "bootable/recovery/partitionmanager.cpp"

        # yogi's metadata decrypt sets up dm-default-key for 8 devices, each doing a slow
        # keymint storage-key upgrade (ERROR_KEY_REQUIRES_UPGRADE), which can exceed the
        # 30s cap and get killed. Raise it so /data mounts reliably.
        self.CHANGES = [
            (
                r"""				TWFunc::Path_Exists(additional_fstab) ? additional_fstab : "",
				30)) {""",
                r"""				TWFunc::Path_Exists(additional_fstab) ? additional_fstab : "",
				120)) {""",
            ),
        ]
