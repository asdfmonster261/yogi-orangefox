from patch import BaseSubPatch, Colors

class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "Custom DE modifications (Decrypt.cpp)"
        self.target_file = "system/vold/Decrypt.cpp" # bootable/recovery/gui/gui.cpp

        # Список изменений: [(Оригинал, Модификация), ...]
        self.CHANGES = [
            (
                # Блок 1: Оригинальный код для поиска
                r"""
extern "C" bool Decrypt_DE() {
	printf("Attempting to initialize DE keys\n");
	if (!fscrypt_initialize_systemwide_keys()) { // this deals with the overarching device encryption
		printf("fscrypt_initialize_systemwide_keys returned fail\n");
		return false;
	}
	if (!fscrypt_init_user0()) {
		printf("fscrypt_init_user0 returned fail\n");
		return false;
	}
	return true;
}

// Crappy functions for debugging, please ignore unless you need to debug
// void output_hex(const std::string& in) {
// 	const char *buf = in.data();
// 	char hex[in.size() * 2 + 1];
// 	unsigned int index;
// 	for (index = 0; index < in.size(); index++)
// 		sprintf(&hex[2 * index], "%02X", buf[index]);
// }
""",
                # Блок 1: Модифицированный код (результат)
                r"""
extern "C" bool Decrypt_DE() {
	printf("Attempting to initialize DE keys\n");
	if (!fscrypt_initialize_systemwide_keys()) { // this deals with the overarching device encryption
		printf("fscrypt_initialize_systemwide_keys returned fail\n");
		return false;
	}
	if (!fscrypt_init_user0()) {
		printf("fscrypt_init_user0 returned fail\n");
		return false;
	}
	return true;
}

extern "C" bool Reset_FBE_Caches() {
	return fscrypt_reset_key_caches();
}

// Crappy functions for debugging, please ignore unless you need to debug
// void output_hex(const std::string& in) {
// 	const char *buf = in.data();
// 	char hex[in.size() * 2 + 1];
// 	unsigned int index;
// 	for (index = 0; index < in.size(); index++)
// 		sprintf(&hex[2 * index], "%02X", buf[index]);
// }
"""
            )
        ]

    def list_changes(self):
        print(f"Файл: {self.target_file}")
        print(f"Всего участков: {len(self.CHANGES)}")
        
        for i, (orig, mod) in enumerate(self.CHANGES, 1):
            orig_lines = orig.strip().split('\n')
            print(f"\n  {Colors.OKBLUE}Участок #{i} (Оригинал - место поиска):{Colors.ENDC}")
            if len(orig_lines) > 2:
                print(f"    {orig_lines[0].strip()}")
                print(f"    ...")
                print(f"    {orig_lines[-1].strip()}")
            else:
                for line in orig_lines: print(f"    {line.strip()}")

            print(f"\n  {Colors.OKGREEN}Результат (Modified):{Colors.ENDC}")
            # Выводим именно тот блок, который вы хотели видеть в --list
            print(mod.strip())
        print(f"\n{Colors.BOLD}{'-' * 60}{Colors.ENDC}")