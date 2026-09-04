from patch import BaseSubPatch, Colors


class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "vold: drop syslog LOG_* macros before libchrome logging.h"
        self.target_file = "system/vold/Decrypt.cpp"
        self.CHANGES = [
            (
                r"""#include <base/threading/platform_thread.h>""",
                r"""// binder_manager.h pulls syslog.h (via android/binder_internal_logging.h),
// whose LOG_WARNING/LOG_ERROR macros then collide with libchrome's LogSeverity
// constants in base/logging.h, reached through platform_thread.h.
#undef LOG_INFO
#undef LOG_WARNING
#undef LOG_ERROR
#undef LOG_FATAL
#include <base/threading/platform_thread.h>""",
            ),
        ]
