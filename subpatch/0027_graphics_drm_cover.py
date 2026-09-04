from patch import BaseSubPatch, Colors

class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "Fold: drive the cover DSI panel (graphics_drm.cpp)"
        self.target_file = "bootable/recovery/minuitwrp/graphics_drm.cpp"

        # find_used_connector_by_type() returns the first connected DSI, which on the
        # Pixel 11 Pro Fold (yogi) is the inner panel (DSI-1). The cover panel (DSI-2)
        # is the one whose touch controller comes up in recovery, so prefer the DSI
        # with the higher connector_type_id. Single-panel devices keep the sole match.
        self.CHANGES = [
            (
                r"""    for (int i = 0; i < resources->count_connectors; i++) {
        drmModeConnector* connector = drmModeGetConnector(fd, resources->connectors[i]);
        if (connector) {
            if ((connector->connector_type == type) &&
                    (connector->connection == DRM_MODE_CONNECTED) &&
                    (connector->count_modes > 0))
                return connector;

            drmModeFreeConnector(connector);
        }
    }
    return nullptr;""",
                r"""    drmModeConnector* best = nullptr;
    for (int i = 0; i < resources->count_connectors; i++) {
        drmModeConnector* connector = drmModeGetConnector(fd, resources->connectors[i]);
        if (connector) {
            if ((connector->connector_type == type) &&
                    (connector->connection == DRM_MODE_CONNECTED) &&
                    (connector->count_modes > 0)) {
                if (!best || connector->connector_type_id > best->connector_type_id) {
                    if (best) drmModeFreeConnector(best);
                    best = connector;
                    continue;
                }
            }
            drmModeFreeConnector(connector);
        }
    }
    return best;"""
            )
        ]
