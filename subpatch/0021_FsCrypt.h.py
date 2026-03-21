from patch import BaseSubPatch, Colors

class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "Custom DE modifications (FsCrypt.h)"
        self.target_file = "system/vold/FsCrypt.h" # bootable/recovery/gui/gui.cpp

        # Список изменений: [(Оригинал, Модификация), ...]
        self.CHANGES = [
            (
                # Блок 1: Оригинальный код для поиска
                r"""
bool fscrypt_prepare_user_storage(const std::string& volume_uuid, userid_t user_id, int flags);
bool fscrypt_destroy_user_storage(const std::string& volume_uuid, userid_t user_id, int flags);

bool fscrypt_destroy_volume_keys(const std::string& volume_uuid);
bool is_metadata_wrapped_key_supported();
bool lookup_key_ref(const std::map<userid_t, UserPolicies>& policy_map, userid_t user_id,
                           std::string* raw_ref);
""",
                # Блок 1: Модифицированный код (результат)
                r"""
bool fscrypt_prepare_user_storage(const std::string& volume_uuid, userid_t user_id, int flags);
bool fscrypt_destroy_user_storage(const std::string& volume_uuid, userid_t user_id, int flags);

bool fscrypt_destroy_volume_keys(const std::string& volume_uuid);
bool fscrypt_reset_key_caches();
bool is_metadata_wrapped_key_supported();
bool lookup_key_ref(const std::map<userid_t, UserPolicies>& policy_map, userid_t user_id,
                           std::string* raw_ref);
"""
            )
        ]

    