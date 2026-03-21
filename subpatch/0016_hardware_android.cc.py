from patch import BaseSubPatch, Colors

class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "Custom hardware modifications (hardware_android.cc)"
        self.target_file = "system/update_engine/aosp/hardware_android.cc" # bootable/recovery/gui/gui.cpp

        # Список изменений: [(Оригинал, Модификация), ...]
        self.CHANGES = [
            (
                # Блок 1: Оригинальный код для поиска
                r"""
bool HardwareAndroid::SchedulePowerwash(bool save_rollback_data) {
  LOG(INFO) << "Scheduling a powerwash to BCB.";
  LOG_IF(WARNING, save_rollback_data) << "save_rollback_data was true but "
                                      << "isn't supported.";
  string err;
  if (!update_bootloader_message({"--wipe_data", "--reason=wipe_data_from_ota"},
                                 &err)) {
    LOG(ERROR) << "Failed to update bootloader message: " << err;
    return false;
  }
  return true;
}
""",
                # Блок 1: Модифицированный код (результат)
                r"""
bool HardwareAndroid::SchedulePowerwash(bool /* save_rollback_data */) {
  // OrangeFox: powerwash disabled — never write --wipe_data to BCB
  LOG(WARNING) << "SchedulePowerwash called but disabled. Not writing to BCB.";
  return true;
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