import os
import sys
import argparse
import importlib.util
import re
from pathlib import Path

# Цвета для терминала
class Colors:
    HEADER = '\033[95m'
    OKBLUE = '\033[94m'
    OKGREEN = '\033[92m'
    WARNING = '\033[93m'
    FAIL = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'

class PatchManager:
    def __init__(self, base_path):
        self.base_path = Path(base_path).resolve()
        self.subpatches_dir = self.base_path / "subpatch"
        self.source_root = self.base_path.parents[2]

    def load_subpatches(self):
        subpatches = []
        if not self.subpatches_dir.exists():
            return subpatches

        script_dir = str(self.base_path)
        if script_dir not in sys.path:
            sys.path.insert(0, script_dir)

        for file in sorted(self.subpatches_dir.glob("*.py")):
            if file.name == "__init__.py": continue
            module_name = file.stem
            spec = importlib.util.spec_from_file_location(module_name, file)
            module = importlib.util.module_from_spec(spec)
            try:
                spec.loader.exec_module(module)
                if hasattr(module, 'SubPatch'):
                    subpatches.append(module.SubPatch(self))
            except Exception as e:
                print(f"{Colors.FAIL}Ошибка загрузки {file.name}: {e}{Colors.ENDC}")
        return subpatches

    def run(self):
        parser = argparse.ArgumentParser(description="OrangeFox Smart Patcher")
        parser.add_argument("--check", action="store_true", help="Проверить статус")
        parser.add_argument("--mod", action="store_true", help="Применить изменения")
        parser.add_argument("--list", nargs='?', const='short', help="Список (all, имя или пусто)")
        
        args = parser.parse_args()
        subpatches = self.load_subpatches()

        if not subpatches:
            print(f"{Colors.WARNING}Сабпатчи не найдены.{Colors.ENDC}")
            return

        if args.check:
            for patch in subpatches:
                print(f"{Colors.HEADER}>>> Модуль: {patch.name}{Colors.ENDC}")
                patch.check()
        elif args.mod:
            for patch in subpatches:
                print(f"{Colors.HEADER}>>> Модуль: {patch.name}{Colors.ENDC}")
                patch.mod()
        elif args.list is not None:
            if args.list == 'short':
                print(f"{Colors.BOLD}{'МОДУЛЬ':<45} | {'ФАЙЛ':<30}{Colors.ENDC}")
                print("-" * 80)
                for patch in subpatches:
                    print(f"{patch.name:<45} | {patch.target_file:<30}")
            elif args.list.lower() == 'all':
                for patch in subpatches:
                    print(f"{Colors.HEADER}>>> Модуль: {patch.name}{Colors.ENDC}")
                    patch.list_changes()
            else:
                found = False
                for patch in subpatches:
                    if args.list.lower() in patch.name.lower():
                        print(f"{Colors.HEADER}>>> Модуль: {patch.name}{Colors.ENDC}")
                        patch.list_changes()
                        found = True
                if not found:
                    print(f"{Colors.FAIL}Сабпатч '{args.list}' не найден.{Colors.ENDC}")

class BaseSubPatch:
    def __init__(self, manager):
        self.manager = manager
        self.target_file = ""
        self.CHANGES = []

    def get_source_path(self):
        if not self.target_file:
            return None
        return self.manager.source_root / self.target_file

    def _prepare_regex(self, text):
        """
        Максимально устойчивый анализатор кода (Тотальная токенизация).
        Разбивает код на слова и отдельные символы пунктуации.
        """
        content = text.strip()
        if not content:
            return ""

        # Находим все слова (буквы/цифры) ИЛИ любой одиночный символ, который не является пробелом
        tokens = re.findall(r'\w+|[^\w\s]', content)
        
        # Экранируем каждый токен и соединяем их через \s*
        escaped_tokens = [re.escape(t) for t in tokens if t]
        
        return r'\s*'.join(escaped_tokens)

    def find_and_check_in_text(self, text, original, modified):
        """Поиск внутри текста с использованием сверхгибких регулярок"""
        # 1. Проверяем на примененный патч
        mod_regex = self._prepare_regex(modified)
        if mod_regex and re.search(mod_regex, text, re.MULTILINE | re.DOTALL):
            return "ALREADY_APPLIED", None
            
        # 2. Ищем оригинал
        orig_regex = self._prepare_regex(original)
        if not orig_regex:
            return "NOT_FOUND_OR_CONFLICT", None
            
        match = re.search(orig_regex, text, re.MULTILINE | re.DOTALL)
        if match:
            return "READY_TO_PATCH", match
        
        return "NOT_FOUND_OR_CONFLICT", None

    def check(self):
        source_path = self.get_source_path()
        if source_path is None or not source_path.exists():
            print(f"  {Colors.FAIL}Файл не найден{Colors.ENDC}: {self.target_file}")
            return

        source = source_path.read_text(errors='ignore')
        for orig, mod in self.CHANGES:
            status, _ = self.find_and_check_in_text(source, orig, mod)
            if status != "ALREADY_APPLIED":
                if status == "READY_TO_PATCH":
                    print(f"  {Colors.WARNING}Ожидает{Colors.ENDC}: {Colors.BOLD}{self.target_file}{Colors.ENDC}")
                else:
                    print(f"  {Colors.FAIL}Конфликт{Colors.ENDC}: Оригинальный блок не совпадает в {Colors.BOLD}{self.target_file}{Colors.ENDC}")
                return
        print(f"  {Colors.OKGREEN}Применено{Colors.ENDC}: {Colors.BOLD}{self.target_file}{Colors.ENDC}")

    def mod(self):
        source_path = self.get_source_path()
        if source_path is None or not source_path.exists() or source_path.is_dir():
            print(f"  {Colors.FAIL}FAIL{Colors.ENDC}: Ошибка пути: {self.target_file}")
            return

        source = source_path.read_text(errors='ignore')
        new_source = source
        modified_flag = False
        
        for orig, mod in self.CHANGES:
            status, match = self.find_and_check_in_text(new_source, orig, mod)
            if status == "READY_TO_PATCH":
                new_source = new_source[:match.start()] + mod.strip() + new_source[match.end():]
                modified_flag = True
                print(f"  [{Colors.OKGREEN}DONE{Colors.ENDC}] Участок в {Colors.BOLD}{self.target_file}{Colors.ENDC} обновлен.")
            elif status == "ALREADY_APPLIED":
                print(f"  [{Colors.OKBLUE}SKIP{Colors.ENDC}] Файл {Colors.BOLD}{self.target_file}{Colors.ENDC} уже содержит изменения.")
            else:
                print(f"  [{Colors.FAIL}FAIL{Colors.ENDC}] Код для замены не найден в {Colors.BOLD}{self.target_file}{Colors.ENDC}.")
        
        if modified_flag:
            source_path.write_text(new_source)

    def list_changes(self):
        """Централизованная функция отображения изменений"""
        print(f"  Файл: {Colors.BOLD}{self.target_file}{Colors.ENDC}")
        print(f"  Всего участков: {len(self.CHANGES)}")
        
        for i, (orig, mod) in enumerate(self.CHANGES, 1):
            orig_lines = orig.strip().split('\n')
            print(f"\n  {Colors.OKBLUE}Участок #{i} (Оригинал - место поиска):{Colors.ENDC}")
            
            if len(orig_lines) > 2:
                print(f"    {orig_lines[0].strip()}")
                print(f"    ...")
                print(f"    {orig_lines[-1].strip()}")
            else:
                for line in orig_lines:
                    print(f"    {line.strip()}")

            print(f"\n  {Colors.OKGREEN}Результат (Modified):{Colors.ENDC}")
            print(mod.strip())
            
        print(f"\n{Colors.BOLD}{'-' * 60}{Colors.ENDC}")

if __name__ == "__main__":
    base_dir = os.path.dirname(os.path.abspath(__file__))
    PatchManager(base_dir).run()