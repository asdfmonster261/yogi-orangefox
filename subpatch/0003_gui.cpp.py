from patch import BaseSubPatch, Colors

class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "Fix power+volume key (gui.cpp)"
        self.target_file = "bootable/recovery/gui/gui.cpp"

        # Список изменений: [(Оригинал, Модификация), ...]
        self.CHANGES = [
            (
                # Блок 1: Оригинальный код для поиска
                r"""
			} else {
				blankTimer.toggleBlank();
			}
		} else {
			if (ev.code == KEY_POWER && key_status != KS_KEY_REPEAT) {
				LOGEVENT("POWER Key Released\n");
				blankTimer.toggleBlank();
			}
		}
""",
                # Блок 1: Модифицированный код (результат)
                r"""
			} else {
				blankTimer.toggleBlank();
			}
		} else {
			if (ev.code == KEY_POWER && key_status != KS_KEY_REPEAT
			    && !kb->IsKeyDown(KEY_VOLUMEUP) && !kb->IsKeyDown(KEY_VOLUMEDOWN)) {
				LOGEVENT("POWER Key Released\n");
				blankTimer.toggleBlank();
			}
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