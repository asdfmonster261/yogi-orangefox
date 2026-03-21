from patch import BaseSubPatch, Colors

class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "Disable SPL downgrade check (spl_check.cpp)"
        self.target_file = "bootable/recovery/install/spl_check.cpp" # bootable/recovery/gui/gui.cpp

        # Список изменений: [(Оригинал, Модификация), ...]
        self.CHANGES = [
            (
                # Блок 1: Оригинальный код для поиска
                r"""
bool ViolatesSPLDowngrade(const build::tools::releasetools::OtaMetadata& metadata,
                          std::string_view current_spl) {
  const auto& post_spl = metadata.postcondition().security_patch_level();
  if (current_spl.empty()) {
    LOG(WARNING) << "Failed to get device's current security patch level. Target SPL is "
                 << post_spl << " permitting OTA install";
    return false;
  }
  // SPL(security patch level) is expected to be in format yyyy-mm-dd, e.g.  2018-05-29. Given this
  // specific format, comparing two SPL can be done by just regular string comparison. If the format
  // must lay out year/month/date in the exact order, and must properly prepend dates with 0(for
  // example, 05 for May). Otherwise this comparison doesn't work. We don't expect SPL date formats
  // to change, leave this as is.
  if (post_spl < current_spl) {
    LOG(ERROR) << "Current SPL: " << current_spl << " Target SPL: " << post_spl
               << " this is considered a downgrade";
    if (metadata.spl_downgrade() || metadata.downgrade()) {
      LOG(WARNING)
          << "SPL downgrade detected, but OTA package explicitly permitts this(OtaMetadata has "
             "spl_downgrade / downgrade bit set).Permitting update anyway.Installing a SPL "
             "downgrade OTA can cause /data fail to decrypt and device fails to boot.";
      return false;
    }
    return true;
  } else {
    LOG(INFO) << "old spl: " << current_spl << " new spl: " << post_spl << " CHECK passes";
  }
  return false;
}
""",
                # Блок 1: Модифицированный код (результат)
                r"""
bool ViolatesSPLDowngrade(const build::tools::releasetools::OtaMetadata& /* metadata */,
                          std::string_view /* current_spl */) {
  // OrangeFox: SPL downgrade check disabled — allow any OTA
  LOG(INFO) << "ViolatesSPLDowngrade: check disabled, permitting OTA";
  return false;
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