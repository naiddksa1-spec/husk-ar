/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Husk -- DisplayChangeListener bridge.  See husk-display.h.
 *
 * Written fresh rather than adapted from UTM's CocoaSpice, which is Apache-2.0
 * and therefore incompatible with QEMU's GPLv2. See docs/01-licensing.md.
 */

#include "qemu/osdep.h"
#include "qemu/main-loop.h"
#include "qemu/thread.h"
#include "ui/console.h"
#include "ui/input.h"
#include "qapi/error.h"
#include "qapi/util.h"
#include "qapi/qapi-types-ui.h"

#include "husk-display.h"

#include <os/log.h>
#include <sys/time.h>
#include <stdatomic.h>

static double husk_dpy_now_ms(void)
{
    struct timeval tv;
    static _Atomic uint64_t base_ms;
    uint64_t now;
    uint64_t base = 0;

    gettimeofday(&tv, NULL);
    now = (uint64_t)tv.tv_sec * 1000u + (uint64_t)tv.tv_usec / 1000u;
    atomic_compare_exchange_strong_explicit(&base_ms, &base, now,
                                             memory_order_relaxed,
                                             memory_order_relaxed);
    base = atomic_load_explicit(&base_ms, memory_order_relaxed);
    return (double)(now - base);
}

#define HUSK_DLOG(fmt, ...)                                                    \
    do {                                                                       \
        os_log(OS_LOG_DEFAULT, "[husk-dpy] " fmt, ##__VA_ARGS__);              \
        fprintf(stderr, "[%9.2fms][husk-dpy] " fmt "\n",                       \
                husk_dpy_now_ms(), ##__VA_ARGS__);                             \
        fflush(stderr);                                                        \
    } while (0)

typedef struct HuskDisplayState {
    DisplayChangeListener dcl;
    QemuMutex             lock;

    DisplaySurface *surface;
    uint64_t        generation;
    uint64_t        sequence;
    _Atomic bool    inited;
} HuskDisplayState;

static HuskDisplayState husk;

/* ------------------------------------------------------------ DCL callbacks */
/* All of these run on the QEMU main-loop thread with the BQL held. */

static void husk_dpy_gfx_update(DisplayChangeListener *dcl,
                                int x, int y, int w, int h)
{
    (void)dcl;
    /*
     * Deliberately not tracking dirty rectangles. The guest framebuffer for a
     * phone-sized surface uploads to a Metal texture in well under a frame, and
     * partial-rect bookkeeping across two threads buys nothing until that stops
     * being true. Revisit if profiling on device says otherwise.
     */
    uint64_t seq = qatomic_fetch_inc(&husk.sequence) + 1;

    /* The first few draws are the interesting ones -- they prove the guest is
     * alive and rendering. After that, nothing: this runs with the BQL held,
     * and even a sparse fprintf+fflush steals time from every vCPU. The
     * sequence is exported for the UI's diagnostics instead. */
    if (seq <= 5) {
        HUSK_DLOG("gfx_update #%llu rect=%dx%d@%d,%d",
                  (unsigned long long)seq, w, h, x, y);
    }
}

static void husk_dpy_gfx_switch(DisplayChangeListener *dcl,
                                DisplaySurface *new_surface)
{
    (void)dcl;
    qemu_mutex_lock(&husk.lock);
    husk.surface = new_surface;
    husk.generation++;
    uint64_t gen = husk.generation;
    qemu_mutex_unlock(&husk.lock);

    /*
     * Not counted as a frame.
     *
     * It used to be, and that made every frame-rate number twice what it
     * should have been: virtio-gpu issues exactly one gfx_update per flip, so
     * counting both meant counting each frame in two places. The log showed it
     * plainly -- "gfx_update #1800" and "gfx_switch gen=900" on the same
     * millisecond. A frame is a draw, and gfx_update is the draw.
     *
     * The old path logged this sparsely, but this runs on the main loop with
     * the BQL held, so every line written here is time no vCPU can run.
     */
    /* Only the first few: surface replacement is on the BQL path too. */
    if (gen <= 5) {
        HUSK_DLOG("gfx_switch gen=%llu surface=%p %dx%d",
                  (unsigned long long)gen, (void *)new_surface,
                  new_surface ? surface_width(new_surface) : 0,
                  new_surface ? surface_height(new_surface) : 0);
    }
}

static bool husk_dpy_gfx_check_format(DisplayChangeListener *dcl,
                                      pixman_format_code_t format)
{
    (void)dcl;
    /* 32bpp only: it is what virtio-gpu gives us and what Metal wants. */
    bool ok = (format == PIXMAN_x8r8g8b8 || format == PIXMAN_a8r8g8b8);
    HUSK_DLOG("gfx_check_format 0x%x -> %s", (unsigned)format, ok ? "accept" : "reject");
    return ok;
}

static void husk_dpy_refresh(DisplayChangeListener *dcl)
{
    graphic_hw_update(dcl->con);
}

static const DisplayChangeListenerOps husk_dcl_ops = {
    .dpy_name             = "husk",
    .dpy_refresh          = husk_dpy_refresh,
    .dpy_gfx_update       = husk_dpy_gfx_update,
    .dpy_gfx_switch       = husk_dpy_gfx_switch,
    .dpy_gfx_check_format = husk_dpy_gfx_check_format,
};

/* ------------------------------------------------------------- public API */

void husk_display_init(void)
{
    if (atomic_load_explicit(&husk.inited, memory_order_acquire)) {
        HUSK_DLOG("init: already initialised, ignoring");
        return;
    }
    HUSK_DLOG("init: registering DisplayChangeListener");

    qemu_mutex_init(&husk.lock);
    husk.dcl.ops = &husk_dcl_ops;
    husk.dcl.con = qemu_console_lookup_by_index(0);

    if (husk.dcl.con == NULL) {
        /* The most likely way this whole path fails quietly. With -display none
         * QEMU still creates a console for the graphics device, but if the device
         * is missing or named differently there is nothing to attach to, and every
         * later symptom is just "black screen". */
        HUSK_DLOG("init: FATAL -- qemu_console_lookup_by_index(0) returned NULL. "
                  "No graphics console exists; check that -device virtio-gpu-pci "
                  "is on the command line.");
        return;
    }
    HUSK_DLOG("init: console[0]=%p graphic=%d",
              (void *)husk.dcl.con, QEMU_IS_GRAPHIC_CONSOLE(husk.dcl.con) ? 1 : 0);

    register_displaychangelistener(&husk.dcl);
    atomic_store_explicit(&husk.inited, true, memory_order_release);
    HUSK_DLOG("init: listener registered; QEMU will now drive dpy_refresh");
}

bool husk_display_lock_frame(HuskFrameInfo *out)
{
    if (!atomic_load_explicit(&husk.inited, memory_order_acquire) || out == NULL) {
        return false;
    }
    qemu_mutex_lock(&husk.lock);
    if (husk.surface == NULL) {
        qemu_mutex_unlock(&husk.lock);
        return false;
    }
    out->pixels     = surface_data(husk.surface);
    out->width      = surface_width(husk.surface);
    out->height     = surface_height(husk.surface);
    out->stride     = surface_stride(husk.surface);
    out->bpp        = surface_bits_per_pixel(husk.surface);
    out->generation = husk.generation;
    out->sequence   = qatomic_read(&husk.sequence);

    if (out->pixels == NULL || out->width <= 0 || out->height <= 0) {
        qemu_mutex_unlock(&husk.lock);
        return false;
    }
    return true; /* caller must unlock */
}

void husk_display_unlock_frame(void)
{
    if (atomic_load_explicit(&husk.inited, memory_order_acquire)) {
        qemu_mutex_unlock(&husk.lock);
    }
}

uint64_t husk_display_sequence(void)
{
    return atomic_load_explicit(&husk.inited, memory_order_acquire)
         ? qatomic_read(&husk.sequence) : 0;
}

/*
 * Input belongs to the machine, not to whichever display is drawing it.
 *
 * Every function below used to open with `if (!husk.inited) return;` and send
 * to husk.dcl.con -- the software listener's console. husk_display_init() only
 * runs when GL fails, so on a GPU-backed guest the entire input path was a
 * silent early return: a touch was mapped, scaled, clamped, and then dropped
 * before it reached even a log line. Touch had never worked in GPU mode.
 *
 * Console 0 is the guest's display in both modes, so ask for it directly and
 * fall back to the software listener's console only because it is already
 * resolved when that path is the live one.
 */
static QemuConsole *husk_input_console(void)
{
    if (husk.dcl.con) {
        return husk.dcl.con;
    }
    return qemu_console_lookup_by_index(0);
}

/*
 * The guest's resolution, from the console rather than from a DisplaySurface.
 *
 * In GL mode there is no surface to measure -- the picture is a texture that
 * never passes through QEMU. The console knows the size either way, because
 * virtio-gpu calls qemu_console_resize() as part of setting a scanout.
 */
static void husk_input_size(QemuConsole *con, int *w, int *h)
{
    *w = con ? qemu_console_get_width(con, 0) : 0;
    *h = con ? qemu_console_get_height(con, 0) : 0;
    if (*w > 0 && *h > 0) {
        return;
    }
    qemu_mutex_lock(&husk.lock);
    *w = husk.surface ? surface_width(husk.surface) : 0;
    *h = husk.surface ? surface_height(husk.surface) : 0;
    qemu_mutex_unlock(&husk.lock);
}

/*
 * Ask the guest to make its display this size.
 *
 * Rotating Android inside a fixed portrait panel was the wrong shape of fix:
 * Android honoured the rotation and then letterboxed the app into a
 * sub-rectangle, so the picture was small and -- because the window accepting
 * input was that rectangle and not where the finger mapped to -- correctly
 * placed touches went nowhere.
 *
 * This is what QEMU provides for the case: dpy_set_ui_info() hands the guest a
 * preferred geometry, its virtio-gpu driver does a modeset, and the scanout
 * genuinely becomes that size. Android then has a real landscape display rather
 * than a portrait one it has to fit a landscape app into, and nothing needs
 * rotating anywhere -- not the shader, not the touch map.
 */
/*
 * What the guest's display actually is, right now.
 *
 * Distinct from what we asked for. A modeset request is a suggestion: the guest
 * driver may act on it, and Android's compositor may or may not reflow behind
 * that. Reading the console back is the only way to know which happened, and
 * landscape has to behave whichever way it goes.
 */
void husk_display_guest_size(int32_t *width, int32_t *height)
{
    QemuConsole *con;
    int w = 0, h = 0;
    bool held = bql_locked();

    if (!held) {
        bql_lock();
    }
    con = husk_input_console();
    husk_input_size(con, &w, &h);
    if (!held) {
        bql_unlock();
    }
    if (width)  { *width  = w; }
    if (height) { *height = h; }
}

void husk_display_set_ui_size(int32_t width, int32_t height)
{
    QemuConsole *con;
    QemuUIInfo info;

    if (width <= 0 || height <= 0) {
        return;
    }
    /*
     * Take the lock only if it is not already held.
     *
     * This runs from two places with opposite expectations. From the UI thread
     * the BQL is free and must be taken. Immediately after qemu_init() returns
     * it is already held -- QEMU keeps it from init until the main loop starts
     * -- and taking it again trips "assertion failed: (!bql_locked())". The
     * first version asserted before qemu_init because the mutex did not exist
     * yet; the second asserted after it because the mutex was already ours.
     */
    bool held = bql_locked();
    if (!held) {
        bql_lock();
    }
    con = husk_input_console();
    if (con) {
        info = *dpy_get_ui_info(con);
        info.width = width;
        info.height = height;
        dpy_set_ui_info(con, &info, false);
    }
    if (!held) {
        bql_unlock();
    }
    HUSK_DLOG("asked the guest for a %dx%d display (console %p)",
              width, height, (void *)con);
}

void husk_display_send_pointer(int32_t x, int32_t y, bool button_down)
{
    QemuConsole *con;
    int w, h;

    /*
     * qemu_input_* must run under the BQL. Taking it here rather than marshalling
     * through a bottom half keeps touch latency down; the hold is a few
     * microseconds and the UI thread blocking that long is not perceptible.
     */
    bool held = bql_locked();
    if (!held) {
        bql_lock();
    }
    con = husk_input_console();
    husk_input_size(con, &w, &h);

    static uint64_t pointer_events;
    uint64_t ev = qatomic_fetch_inc(&pointer_events) + 1;

    if (con && w > 0 && h > 0) {
        if (x < 0) { x = 0; } else if (x >= w) { x = w - 1; }
        if (y < 0) { y = 0; } else if (y >= h) { y = h - 1; }
        qemu_input_queue_abs(con, INPUT_AXIS_X, x, 0, w);
        qemu_input_queue_abs(con, INPUT_AXIS_Y, y, 0, h);
        qemu_input_queue_btn(con, INPUT_BUTTON_LEFT, button_down);
        qemu_input_event_sync();
        if (!held && (ev <= 20 || (ev % 200) == 0)) {
            HUSK_DLOG("pointer #%llu -> guest (%d,%d) down=%d [surface %dx%d]",
                      (unsigned long long)ev, x, y, button_down ? 1 : 0, w, h);
        }
    } else {
        if (!held) {
            HUSK_DLOG("pointer #%llu DROPPED -- console=%p size=%dx%d",
                      (unsigned long long)ev, (void *)con, w, h);
        }
    }
    if (!held) {
        bql_unlock();
    }
}

bool husk_display_send_key(const char *qcode_name, bool down)
{
    QemuConsole *con;

    if (qcode_name == NULL) {
        return false;
    }

    /*
     * Resolved by name through QEMU's own QKeyCode table rather than by passing a
     * raw enum value across the boundary. The numbers are positional in
     * qapi/ui.json -- 162 of them -- so hardcoding them on the Swift side would
     * silently remap every key the moment that list gains an entry.
     */
    int qcode = qapi_enum_parse(&QKeyCode_lookup, qcode_name, -1, NULL);
    if (qcode < 0) {
        HUSK_DLOG("key '%s' is not a QKeyCode; ignored", qcode_name);
        return false;
    }

    static uint64_t keys;
    uint64_t n = qatomic_fetch_inc(&keys) + 1;

    bool held = bql_locked();
    if (!held) {
        bql_lock();
    }
    con = husk_input_console();
    if (con) {
        qemu_input_event_send_key_qcode(con, (QKeyCode)qcode, down);
    }
    if (!held) {
        bql_unlock();
    }
    if (!con) {
        if (!held) {
            HUSK_DLOG("key '%s' dropped -- no console", qcode_name);
        }
        return false;
    }

    if (!held && (n <= 20 || (n % 100) == 0)) {
        HUSK_DLOG("key #%llu '%s' (qcode %d) down=%d",
                  (unsigned long long)n, qcode_name, qcode, down ? 1 : 0);
    }
    return true;
}

void husk_display_request_update(void)
{
    if (!atomic_load_explicit(&husk.inited, memory_order_acquire)
        || husk.dcl.con == NULL) {
        return;
    }
    bool held = bql_locked();
    if (!held) {
        bql_lock();
    }
    graphic_hw_update(husk.dcl.con);
    if (!held) {
        bql_unlock();
    }
}
