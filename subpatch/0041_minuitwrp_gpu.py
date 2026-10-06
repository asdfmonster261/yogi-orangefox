from patch import BaseSubPatch


class SubPatch(BaseSubPatch):
    def __init__(self, manager):
        super().__init__(manager)
        self.name = "minuitwrp: draw with the phone's GPU when its driver is staged"
        self.target_file = "bootable/recovery/minuitwrp/graphics.cpp"

        # minuitwrp_gl (selfcode/minuitwrp_gl) does the drawing; each gr_* function
        # hands over to it while it is active and keeps its CPU path otherwise.
        self.CHANGES = [
            (
                r"""
#include "minuitwrp/truetype.hpp"
""",
                r"""
#include "minuitwrp/truetype.hpp"
#include "minuitwrp_gl.h"
"""
            ),
            (
                r"""
void gr_clip(int x, int y, int w, int h)
{
    GGLContext *gl = gr_context;
""",
                r"""
void gr_clip(int x, int y, int w, int h)
{
    if (gr_gl_active()) {
        gr_gl_clip(x, y, w, h);
        return;
    }
    GGLContext *gl = gr_context;
"""
            ),
            (
                r"""
void gr_noclip()
{
    GGLContext *gl = gr_context;
""",
                r"""
void gr_noclip()
{
    if (gr_gl_active()) {
        gr_gl_noclip();
        return;
    }
    GGLContext *gl = gr_context;
"""
            ),
            (
                r"""
void gr_line(int x0, int y0, int x1, int y1, int width)
{
    GGLContext *gl = gr_context;
""",
                r"""
void gr_line(int x0, int y0, int x1, int y1, int width)
{
    if (gr_gl_active()) {
        gr_gl_line(x0, y0, x1, y1, width);
        return;
    }
    GGLContext *gl = gr_context;
"""
            ),
            (
                r"""
void gr_color(unsigned char r, unsigned char g, unsigned char b, unsigned char a)
{
    GGLContext *gl = gr_context;
""",
                r"""
void gr_color(unsigned char r, unsigned char g, unsigned char b, unsigned char a)
{
    gr_gl_color(r, g, b, a);
    GGLContext *gl = gr_context;
"""
            ),
            (
                r"""
void gr_clear()
{
    if (gr_draw->pixel_bytes == 2) {
""",
                r"""
void gr_clear()
{
    if (gr_gl_active()) {
        gr_gl_clear(gr_current_r, gr_current_g, gr_current_b, 255);
        return;
    }
    if (gr_draw->pixel_bytes == 2) {
"""
            ),
            (
                r"""
void gr_fill(int x, int y, int w, int h)
{
    GGLContext *gl = gr_context;
""",
                r"""
void gr_fill(int x, int y, int w, int h)
{
    if (gr_gl_active()) {
        gr_gl_fill(std::min(x, x + w), std::min(y, y + h), std::max(x, x + w), std::max(y, y + h));
        return;
    }
    GGLContext *gl = gr_context;
"""
            ),
            (
                r"""
void gr_blit(gr_surface source, int sx, int sy, int w, int h, int dx, int dy)
{
    if (gr_context == NULL) {
        return;
    }
""",
                r"""
void gr_blit(gr_surface source, int sx, int sy, int w, int h, int dx, int dy)
{
    if (gr_context == NULL) {
        return;
    }
    if (gr_gl_active()) {
        gr_gl_blit((GGLSurface*) source, sx, sy, std::min(dx, dx + w), std::min(dy, dy + h),
                   std::max(dx, dx + w), std::max(dy, dy + h));
        return;
    }
"""
            ),
            (
                r"""
void gr_flip() {
    gr_draw = gr_backend->flip(gr_backend);
""",
                r"""
void gr_flip() {
#ifdef HAS_DRM
    // The GPU draws straight into the scanout buffers, so there is no frame to copy.
    if (gr_gl_active()) {
        gr_gl_present(drm_gl_back_buffer());
        if (gr_gl_active()) {
            drm_gl_flip();
            return;
        }
    }
#endif
    gr_draw = gr_backend->flip(gr_backend);
"""
            ),
            (
                r"""
    gl->activeTexture(gl, 0);
    gl->enable(gl, GGL_BLEND);
    gl->blendFunc(gl, GGL_SRC_ALPHA, GGL_ONE_MINUS_SRC_ALPHA);

    gr_flip();
    gr_flip();
""",
                r"""
    gl->activeTexture(gl, 0);
    gl->enable(gl, GGL_BLEND);
    gl->blendFunc(gl, GGL_SRC_ALPHA, GGL_ONE_MINUS_SRC_ALPHA);

#ifdef HAS_DRM
    if (gr_rotation == 0 && gr_backend == open_drm()) {
        gr_gl_buffer buffers[2];
        const int count = drm_gl_buffers(buffers, 2);
        if (count > 0)
            drm_gl_use(gr_gl_init(buffers, count));
    }
#endif

    gr_flip();
    gr_flip();
"""
            ),
            (
                r"""
void gr_exit(void)
{
    gr_backend->exit(gr_backend);
}
""",
                r"""
void gr_exit(void)
{
    gr_gl_exit();
    gr_backend->exit(gr_backend);
}
"""
            ),
            (
                r"""
    // Now, copy the data
    memcpy(ms->data, gr_mem_surface.data,
""",
                r"""
    // Now, copy the data
    if (gr_gl_active())
        gr_gl_read(gr_mem_surface.data, gr_draw->row_bytes);
    memcpy(ms->data, gr_mem_surface.data,
"""
            ),
            (
                r"""
    GGLSurface* ms = (GGLSurface*) surface;
    free(ms->data);
    free(ms);
""",
                r"""
    GGLSurface* ms = (GGLSurface*) surface;
    gr_gl_forget(ms);
    free(ms->data);
    free(ms);
"""
            ),
            (
                r"""
void gr_write_frame_to_file(int fd)
{
    write(fd, gr_mem_surface.data,
""",
                r"""
void gr_write_frame_to_file(int fd)
{
    if (gr_gl_active())
        gr_gl_read(gr_mem_surface.data, gr_draw->row_bytes);
    write(fd, gr_mem_surface.data,
"""
            ),
        ]

        self.FILES = [
            (self.target_file, self.CHANGES),
            ("bootable/recovery/minuitwrp/graphics.h", [
                (
                    r"""
minui_backend* open_overlay();
""",
                    r"""
minui_backend* open_overlay();

// Scanout buffers for minuitwrp_gl to draw into, and the flip that shows them.
struct gr_gl_buffer;
int drm_gl_buffers(gr_gl_buffer* buffers, int max);
void drm_gl_use(bool use);
int drm_gl_back_buffer();
void drm_gl_flip();
"""
                ),
            ]),
            ("bootable/recovery/minuitwrp/graphics_drm.cpp", [
                (
                    r"""
#include "graphics.h"
#include <pixelflinger/pixelflinger.h>
""",
                    r"""
#include "graphics.h"
#include <pixelflinger/pixelflinger.h>
#include <linux/dma-heap.h>
#include <sys/ioctl.h>
#include "minuitwrp_gl.h"
"""
                ),
                (
                    r"""
static int drm_fd = -1;
""",
                    r"""
static int drm_fd = -1;
static uint32_t drm_format;
static uint32_t gl_fb_ids[2], gl_handles[2];
"""
                ),
                (
                    r"""
    drm_mode_create_dumb create_dumb = {};
    create_dumb.height = height;
""",
                    r"""
    drm_format = format;
    drm_mode_create_dumb create_dumb = {};
    create_dumb.height = height;
"""
                ),
                (
                    r"""
minui_backend* open_drm() {
    return &drm_backend;
}
""",
                    r"""
minui_backend* open_drm() {
    return &drm_backend;
}

// The GPU cannot import this driver's dumb buffers, so for the GPU the planes scan out
// buffers from a dma-buf heap instead, which the GPU and the display can both use.
int drm_gl_buffers(gr_gl_buffer* buffers, int max) {
    if (max < 2 || !drm_surfaces[0] || !drm_surfaces[1])
        return 0;
    int heap = open("/dev/dma_heap/system-uncached", O_RDONLY | O_CLOEXEC);
    if (heap < 0)
        heap = open("/dev/dma_heap/system", O_RDONLY | O_CLOEXEC);
    if (heap < 0) {
        printf("E:GPU: no dma-buf heap\n");
        return 0;
    }
    int count = 0;
    for (; count < 2; ++count) {
        const GRSurface& base = drm_surfaces[count]->base;
        struct dma_heap_allocation_data alloc = {};
        alloc.len = (uint64_t) base.row_bytes * base.height;
        alloc.fd_flags = O_RDWR | O_CLOEXEC;
        if (ioctl(heap, DMA_HEAP_IOCTL_ALLOC, &alloc))
            break;
        if (drmPrimeFDToHandle(drm_fd, alloc.fd, &gl_handles[count])) {
            close(alloc.fd);
            break;
        }
        uint32_t handles[4] = {}, pitches[4] = {}, offsets[4] = {};
        handles[0] = gl_handles[count];
        pitches[0] = base.row_bytes;
        if (drmModeAddFB2(drm_fd, base.width, base.height, drm_format, handles, pitches, offsets,
                          &gl_fb_ids[count], 0)) {
            close(alloc.fd);
            break;
        }
        buffers[count].fd = alloc.fd;
        buffers[count].fourcc = drm_format;
        buffers[count].width = base.width;
        buffers[count].height = base.height;
        buffers[count].pitch = base.row_bytes;
    }
    close(heap);
    if (count < 2) {
        printf("E:GPU: cannot set up scanout buffer %d from the heap\n", count);
        for (int i = 0; i < count; ++i)
            close(buffers[i].fd);
        drm_gl_use(false);
        return 0;
    }
    return count;
}

// Switches the planes to the heap buffers once the GPU draws into them, or frees them.
void drm_gl_use(bool use) {
    for (int i = 0; i < 2; ++i) {
        if (use) {
            // The dumb buffer stays allocated until drm_exit closes the device.
            drm_surfaces[i]->fb_id = gl_fb_ids[i];
            drm_surfaces[i]->handle = gl_handles[i];
        } else {
            if (gl_fb_ids[i])
                drmModeRmFB(drm_fd, gl_fb_ids[i]);
            if (gl_handles[i]) {
                struct drm_gem_close gem_close = {};
                gem_close.handle = gl_handles[i];
                drmIoctl(drm_fd, DRM_IOCTL_GEM_CLOSE, &gem_close);
            }
        }
        gl_fb_ids[i] = gl_handles[i] = 0;
    }
}

int drm_gl_back_buffer() {
    return current_buffer;
}

void drm_gl_flip() {
    update_plane_fb();
    current_buffer = 1 - current_buffer;
}
"""
                ),
            ]),
            ("bootable/recovery/minuitwrp/truetype.cpp", [
                (
                    r"""
#include "minuitwrp/truetype.hpp"
""",
                    r"""
#include "minuitwrp/truetype.hpp"
#include "minuitwrp_gl.h"
"""
                ),
                (
                    r"""
	StringCacheEntry *e = (StringCacheEntry *)value;
	free(e->surface.data);
	delete e;
""",
                    r"""
	StringCacheEntry *e = (StringCacheEntry *)value;
	gr_gl_forget(&e->surface);
	free(e->surface.data);
	delete e;
"""
                ),
                (
                    r"""
	if (gr_rotation != 0) {
		gl->bindTexture(gl, &string_surface_rotated);
	} else {
		gl->bindTexture(gl, &e->surface);
	}
""",
                    r"""
	if (gr_gl_active()) {
		gr_gl_text(&e->surface, l_disp, t_disp, r_disp, b_disp);
		pthread_mutex_unlock(&font->mutex);
		return res;
	}

	if (gr_rotation != 0) {
		gl->bindTexture(gl, &string_surface_rotated);
	} else {
		gl->bindTexture(gl, &e->surface);
	}
"""
                ),
            ]),
            ("bootable/recovery/minuitwrp/resources.cpp", [
                (
                    r"""
#include "minuitwrp/minui.h"
""",
                    r"""
#include "minuitwrp/minui.h"
#include "minuitwrp_gl.h"
"""
                ),
                (
                    r"""
void res_free_surface(gr_surface surface) {
    GGLSurface* pSurface = (GGLSurface*) surface;
    if (pSurface) {
        free(pSurface);
""",
                    r"""
void res_free_surface(gr_surface surface) {
    GGLSurface* pSurface = (GGLSurface*) surface;
    if (pSurface) {
        gr_gl_forget(pSurface);
        free(pSurface);
"""
                ),
            ]),
            ("bootable/recovery/minuitwrp/graphics_utils.cpp", [
                (
                    r"""
#include "minuitwrp/minui.h"
""",
                    r"""
#include "minuitwrp/minui.h"
#include "minuitwrp_gl.h"
"""
                ),
                (
                    r"""
    fp = fopen(dest, "wb");
""",
                    r"""
    if (gr_gl_active())
        gr_gl_read(gr_mem_surface.data, gr_mem_surface.stride * gr_draw->pixel_bytes);

    fp = fopen(dest, "wb");
"""
                ),
            ]),
            ("bootable/recovery/minuitwrp/Android.bp", [
                (
                    r"""
    static_libs: ["libpixelflinger_twrp"]
}
""",
                    r"""
    static_libs: ["libpixelflinger_twrp"],
    whole_static_libs: ["//device/google/pixels:libminuitwrp_gl"]
}
"""
                ),
            ]),
        ]

    # BaseSubPatch handles one file; this change spans seven.
    def _each(self, step):
        for self.target_file, self.CHANGES in self.FILES:
            step()
        self.target_file, self.CHANGES = self.FILES[0]

    def check(self):
        self._each(super().check)

    def mod(self):
        self._each(super().mod)

    def list_changes(self):
        self._each(super().list_changes)
