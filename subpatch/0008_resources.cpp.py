from patch import BaseSubPatch, Colors

class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "Custom resources logic (resources.cpp)"
        self.target_file = "bootable/recovery/minuitwrp/resources.cpp" # bootable/recovery/gui/gui.cpp

        # Список изменений: [(Оригинал, Модификация), ...]
        self.CHANGES = [
            (
                # Блок 1: Оригинальный код для поиска
                r"""
    surface = init_display_surface(width, height);
    if (surface == NULL) {
        result = -8;
        goto exit;
    }

#if defined(RECOVERY_ARGB) || defined(RECOVERY_BGRA) || defined(RECOVERY_ABGR)
    png_set_bgr(png_ptr);
#endif

    p_row = reinterpret_cast<unsigned char*>(malloc(width * 4));
    if (p_row == NULL) {
        result = -9;
        goto exit;
    }
""",
                # Блок 1: Модифицированный код (результат)
                r"""
    surface = init_display_surface(width, height);
    if (surface == NULL) {
        result = -8;
        goto exit;
    }

#if defined(RECOVERY_ARGB) || defined(RECOVERY_BGRA)
    png_set_bgr(png_ptr);
#endif

    p_row = reinterpret_cast<unsigned char*>(malloc(width * 4));
    if (p_row == NULL) {
        result = -9;
        goto exit;
    }
"""
            ),
            (
                # Блок 1: Оригинальный код для поиска
                r"""
        for(x = width - 1; x >= 0; x--) {
            int sx = x * 3;
            int dx = x * 4;
            unsigned char r = pRow[sx];
            unsigned char g = pRow[sx + 1];
            unsigned char b = pRow[sx + 2];
            unsigned char a = 0xff;
#if defined(RECOVERY_ARGB) || defined(RECOVERY_BGRA) || defined(RECOVERY_ABGR)
            pRow[dx    ] = b; // r
            pRow[dx + 1] = g; // g
            pRow[dx + 2] = r; // b
            pRow[dx + 3] = a;
#else
""",
                # Блок 1: Модифицированный код (результат)
                r"""
        for(x = width - 1; x >= 0; x--) {
            int sx = x * 3;
            int dx = x * 4;
            unsigned char r = pRow[sx];
            unsigned char g = pRow[sx + 1];
            unsigned char b = pRow[sx + 2];
            unsigned char a = 0xff;
#if defined(RECOVERY_ARGB) || defined(RECOVERY_BGRA)
            pRow[dx    ] = b; // r
            pRow[dx + 1] = g; // g
            pRow[dx + 2] = r; // b
            pRow[dx + 3] = a;
#else
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