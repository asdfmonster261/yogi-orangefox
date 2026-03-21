from patch import BaseSubPatch, Colors

class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "Move to public (partitions.cpp)"
        self.target_file = "bootable/recovery/partitions.hpp" # bootable/recovery/gui/gui.cpp

        # Список изменений: [(Оригинал, Модификация), ...]
        self.CHANGES = [
            (
                # Блок 1: Оригинальный код для поиска
                r"""
    	int Run_OTA_Survival_Restore(const string& Restore_Name);                 // Restore OTA survival
    	void Fox_Set_Dynamic_Partition_Props();					  // Set the OrangeFox dynamic partitions props
 	bool Prepare_All_Super_Volumes();					  // Prepare all known super volumes from super partition

	std::string Get_Bare_Partition_Name(std::string Mount_Point);
   
     	bool Prepare_Super_Volume(TWPartition* twrpPart);				  // Prepare logical super partition volume for mounting
""",
                # Блок 1: Модифицированный код (результат)
                r"""
    	int Run_OTA_Survival_Restore(const string& Restore_Name);                 // Restore OTA survival
    	void Fox_Set_Dynamic_Partition_Props();					  // Set the OrangeFox dynamic partitions props
 	bool Prepare_All_Super_Volumes();					  // Prepare all known super volumes from super partition
    void Mark_User_Decrypted(int userID);                                     // Marks given user ID in Users_List as decrypted
	void Check_Users_Decryption_Status();                                      // Checks to see if all users are decrypted
	void Reset_Users_Decryption_Status();  
	std::string Get_Bare_Partition_Name(std::string Mount_Point);
   
     	bool Prepare_Super_Volume(TWPartition* twrpPart);				  // Prepare logical super partition volume for mounting
"""
            ),
            (
                # Блок 1: Оригинальный код для поиска
                r"""
	Backup_Method_enum Backup_Method;                                         // Method used for backup
	std::string original_ramdisk_format;                                      // Ramdisk format of boot partition
	std::string repacked_ramdisk_format;                                      // Ramdisk format of boot image to repack from
	void Mark_User_Decrypted(int userID);                                     // Marks given user ID in Users_List as decrypted
	void Check_Users_Decryption_Status();                                      // Checks to see if all users are decrypted

private:
	std::vector<TWPartition*> Partitions;                                     // Vector list of all partitions
""",
                # Блок 1: Модифицированный код (результат)
                r"""
	Backup_Method_enum Backup_Method;                                         // Method used for backup
	std::string original_ramdisk_format;                                      // Ramdisk format of boot partition
	std::string repacked_ramdisk_format;                                      // Ramdisk format of boot image to repack from
	                                    // Resets all users to undecrypted state after /data remount

private:
	std::vector<TWPartition*> Partitions;                                     // Vector list of all partitions
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