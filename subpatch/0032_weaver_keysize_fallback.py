from patch import BaseSubPatch, Colors


class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "vold: fall back to 16-byte weaver key size when HAL config is 0"
        self.target_file = "system/vold/Weaver1.cpp"

        # The recovery weaver HAL (Titan M3, AIDL) returns a config with keySize=0, which
        # makes WeaverVerify send an empty key and fail. Fall back to the standard Android
        # weaver key size so the escrow read gets a correctly sized key.
        self.CHANGES = [
            (
                r"""bool Weaver::GetKeySize(uint32_t* keySize) {
	if (!GetConfig())
		return false;
	if (mAidlDevice != nullptr) {
		*keySize = aidlConfig.keySize;
		return true;
	}
	*keySize = config.keySize;
	return true;
}""",
                r"""bool Weaver::GetKeySize(uint32_t* keySize) {
	if (!GetConfig())
		return false;
	if (mAidlDevice != nullptr) {
		*keySize = aidlConfig.keySize;
	} else {
		*keySize = config.keySize;
	}
	if (*keySize == 0)
		*keySize = 16;
	return true;
}""",
            ),
        ]
