from patch import BaseSubPatch, Colors

class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "Custom DE modifications (Decrypt.h)"
        self.target_file = "system/vold/Decrypt.h" # bootable/recovery/gui/gui.cpp

        # Список изменений: [(Оригинал, Модификация), ...]
        self.CHANGES = [
            (
                # Блок 1: Оригинальный код для поиска
                r"""
namespace keystore {
    void copySqliteDb();
    int Get_Password_Type(const userid_t user_id, std::string& filename);
    bool Decrypt_DE();
    bool Decrypt_User(const userid_t user_id, const std::string& Password);
}
""",
                # Блок 1: Модифицированный код (результат)
                r"""
namespace keystore {
    void copySqliteDb();
    int Get_Password_Type(const userid_t user_id, std::string& filename);
    bool Decrypt_DE();
    bool Decrypt_User(const userid_t user_id, const std::string& Password);
    bool Reset_FBE_Caches();
}
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