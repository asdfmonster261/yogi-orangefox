from patch import BaseSubPatch


class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "vold: decrypt version 4 synthetic password blobs"
        self.target_file = "system/vold/Decrypt.cpp"

        self.CHANGES = [
            (
                r"""
#define SYNTHETIC_PASSWORD_VERSION_V3 3
#define SYNTHETIC_PASSWORD_PASSWORD_BASED 0
""",
                r"""
#define SYNTHETIC_PASSWORD_VERSION_V3 3
#define SYNTHETIC_PASSWORD_VERSION_V4 4
#define SYNTHETIC_PASSWORD_PASSWORD_BASED 0
"""
            ),
            (
                r"""
		if (*byteptr != SYNTHETIC_PASSWORD_VERSION_V2 && *byteptr != SYNTHETIC_PASSWORD_VERSION_V1
				&& *byteptr != SYNTHETIC_PASSWORD_VERSION_V3) {
""",
                r"""
		if (*byteptr != SYNTHETIC_PASSWORD_VERSION_V2 && *byteptr != SYNTHETIC_PASSWORD_VERSION_V1
				&& *byteptr != SYNTHETIC_PASSWORD_VERSION_V3
				&& *byteptr != SYNTHETIC_PASSWORD_VERSION_V4) {
"""
            ),
            (
                r"""
		if (*synthetic_password_version == SYNTHETIC_PASSWORD_VERSION_V2
				|| *synthetic_password_version == SYNTHETIC_PASSWORD_VERSION_V3) {
			printf("spblob v2 / v3\n");
""",
                r"""
		if (*synthetic_password_version == SYNTHETIC_PASSWORD_VERSION_V2
				|| *synthetic_password_version == SYNTHETIC_PASSWORD_VERSION_V3
				|| *synthetic_password_version == SYNTHETIC_PASSWORD_VERSION_V4) {
			printf("spblob v%d\n", *synthetic_password_version);
"""
            ),
            (
                r"""
			if (*synthetic_password_version == SYNTHETIC_PASSWORD_VERSION_V3) {
				// V3 uses SP800 instead of SHA512
				disk_decryption_secret_key = PersonalizedHashSP800(PERSONALIZATION_FBE_KEY, PERSONALISATION_CONTEXT, (const char*)secret_key, secret_key_real_size);
			} else {
""",
                r"""
			if (*synthetic_password_version == SYNTHETIC_PASSWORD_VERSION_V3
						|| *synthetic_password_version == SYNTHETIC_PASSWORD_VERSION_V4) {
				// V3 and V4 use SP800 instead of SHA512; V4 runs it over HMAC-SHA512
				disk_decryption_secret_key = PersonalizedHashSP800(PERSONALIZATION_FBE_KEY, PERSONALISATION_CONTEXT, (const char*)secret_key, secret_key_real_size,
						*synthetic_password_version == SYNTHETIC_PASSWORD_VERSION_V4);
			} else {
"""
            ),
        ]

        self.FILES = [
            (self.target_file, self.CHANGES),
            ("system/vold/HashPassword.h", [
                (
                    r"""
std::string PersonalizedHashSP800(const char* label, const char* context, const char* key, const size_t key_size);
""",
                    r"""
// One SP800-108 counter-mode block with a 256-bit output, the synthetic password's final
// KDF: HMAC-SHA256 for a version 3 spblob, HMAC-SHA512 for version 4.
std::string PersonalizedHashSP800(const char* label, const char* context, const char* key, const size_t key_size, bool sha512_prf = false);
"""
                ),
            ]),
            ("system/vold/HashPassword.cpp", [
                (
                    r"""
std::string PersonalizedHashSP800(const char* label, const char* context, const char* key, const size_t key_size) {
	HMAC_CTX ctx;
	HMAC_CTX_init(&ctx);
	HMAC_Init_ex(&ctx, key, key_size, EVP_sha256(), NULL);
""",
                    r"""
std::string PersonalizedHashSP800(const char* label, const char* context, const char* key, const size_t key_size, bool sha512_prf) {
	HMAC_CTX ctx;
	HMAC_CTX_init(&ctx);
	HMAC_Init_ex(&ctx, key, key_size, sha512_prf ? EVP_sha512() : EVP_sha256(), NULL);
"""
                ),
                (
                    r"""
	unsigned char output[SHA256_DIGEST_LENGTH];
	unsigned int out_size = 0;
	HMAC_Final(&ctx, output, &out_size);
""",
                    r"""
	// L is 256 bits whatever the PRF, so a SHA512 block is cut to its first 32 bytes below.
	unsigned char output[SHA512_DIGEST_LENGTH];
	unsigned int out_size = 0;
	HMAC_Final(&ctx, output, &out_size);
"""
                ),
            ]),
        ]

    # BaseSubPatch handles one file; this change spans three.
    def _each(self, step):
        for self.target_file, self.CHANGES in self.FILES:
            step()
        self.target_file, self.CHANGES = self.FILES[0]

    def check(self):
        self._each(super().check)

    def mod(self):
        self._each(super().mod)

    def list_changes(self):
        self._each(super().list_changes)
