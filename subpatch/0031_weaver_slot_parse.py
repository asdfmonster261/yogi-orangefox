from patch import BaseSubPatch, Colors


class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "vold: parse packed 5-byte .weaver file (slot at offset 1, big-endian)"
        self.target_file = "system/vold/Decrypt.cpp"

        # Newer Android writes the .weaver file packed: version(1) + slot(4, big-endian),
        # so the slot is at byte offset 1. The old code read it via (int*)data + 1, i.e.
        # byte offset 4, which is out of bounds for the 5-byte file (yogi: 01 00 00 00 01
        # = version 1, slot 1).
        self.CHANGES = [
            (
                r"""		const unsigned char* byteptr = (const unsigned char*)weaver_data.data();
		wd->version = *byteptr;
		// printf("weaver version %i\n", wd->version);
		const int* intptr = (const int*)weaver_data.data() + sizeof(unsigned char);
		wd->slot = *intptr;
		//endianswap(&wd->slot); not needed
		// printf("weaver slot %i\n", wd->slot);""",
                r"""		const unsigned char* byteptr = (const unsigned char*)weaver_data.data();
		wd->version = *byteptr;
		// printf("weaver version %i\n", wd->version);
		if (weaver_data.size() == 5) {
			// packed layout: version(1) + slot(4, big-endian)
			wd->slot = ((int)byteptr[1] << 24) | ((int)byteptr[2] << 16) |
			           ((int)byteptr[3] << 8) | (int)byteptr[4];
		} else {
			const int* intptr = (const int*)weaver_data.data() + sizeof(unsigned char);
			wd->slot = *intptr;
		}
		// printf("weaver slot %i\n", wd->slot);""",
            ),
        ]
