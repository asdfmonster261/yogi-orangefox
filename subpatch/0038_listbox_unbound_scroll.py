from patch import BaseSubPatch, Colors

class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "Do not scroll unbound listboxes to the end (listbox.cpp)"
        self.target_file = "bootable/recovery/gui/listbox.cpp"

        # Scrolling to the item matching the listbox variable is right for a list
        # that has one, and mVisibleItems.size()-1 is that item's index because it
        # was just pushed. A listbox with no variable has an empty mVariable, and a
        # general refresh passes an empty varName, so the guard passes and every
        # item's empty variableValue matches the empty currentValue: the list ends
        # up scrolled to its last item. Only lists too long to fit show it, which
        # is why the advanced page always opened at the bottom.
        self.CHANGES = [
            (
                r"""		else if (varName == mVariable) {
			if (item.variableValue == currentValue) {""",
                r"""		else if (varName == mVariable && !mVariable.empty()) {
			if (item.variableValue == currentValue) {"""
            ),
        ]
