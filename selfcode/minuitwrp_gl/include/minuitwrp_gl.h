/*
 * minuitwrp_gl - draws the recovery GUI with the phone's own GPU driver.
 *
 * minuitwrp calls these from its gr_* functions while gr_gl_active() is true and draws
 * on the CPU otherwise. Coordinates are display pixels with the origin at the top left,
 * the same as the CPU path's.
 */
#pragma once

#include <stdint.h>

#include <pixelflinger/pixelflinger.h>

struct gr_gl_buffer {
    int fd;  // dma-buf of a scanout buffer; gr_gl_init closes it
    uint32_t fourcc;
    int width;
    int height;
    int pitch;
};

// Starts drawing on the GPU into the given scanout buffers. False leaves the CPU path in
// charge, and so does any later failure.
bool gr_gl_init(const gr_gl_buffer* buffers, int count);
bool gr_gl_active();
void gr_gl_exit();

void gr_gl_color(unsigned char r, unsigned char g, unsigned char b, unsigned char a);
void gr_gl_clip(int x, int y, int w, int h);
void gr_gl_noclip();
void gr_gl_clear(unsigned char r, unsigned char g, unsigned char b, unsigned char a);
void gr_gl_fill(int l, int t, int r, int b);
void gr_gl_line(int x0, int y0, int x1, int y1, int width);
// Draws the surface from (sx, sy) on into the rectangle l,t - r,b.
void gr_gl_blit(const GGLSurface* surface, int sx, int sy, int l, int t, int r, int b);
// Draws an A_8 surface as coverage in the current colour.
void gr_gl_text(const GGLSurface* surface, int l, int t, int r, int b);
// Call before a surface drawn by the functions above is freed.
void gr_gl_forget(const void* surface);
// Copies the frame into dst as RGBA rows, top first, stride bytes apart.
void gr_gl_read(void* dst, int stride);
// Shows the frame: copies it into scanout buffer `index` and waits for the GPU.
void gr_gl_present(int index);
