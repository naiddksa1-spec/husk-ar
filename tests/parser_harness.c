/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "husk-tl-internal.h"
#include "husk-tl-dexindex.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    if (argc != 3) return 2;
    if (!strcmp(argv[1], "dex")) {
        int count = tl_dexidx_open(argv[2]);
        if (count < 0) return 1;
        char output[512]; bool st;
        (void)tl_dexidx_has_class("test/A");
        (void)tl_dexidx_super("test/A", output, sizeof(output));
        (void)tl_dexidx_declares_method("test/A", "run", "()V", &st);
        (void)tl_dexidx_declares_field("test/A", "value", "I", &st);
        (void)tl_dexidx_find_method_lenient("test/A", "run", "()V", output, sizeof(output), &st);
        puts("dex accepted");
        return 0;
    }
    tl_zip z; char err[200];
    if (!tl_zip_open(&z, argv[2], err, sizeof(err))) return 1;
    bool ok = true;
    for (size_t i = 0; i < z.count; i++) {
        const uint8_t *data; size_t len; bool owned;
        if (!tl_zip_data(&z, &z.entries[i], 1024 * 1024, &data, &len, &owned, err, sizeof(err))) {
            ok = false; break;
        }
        if (owned) free((void *)data);
    }
    tl_zip_close(&z);
    return ok ? 0 : 1;
}
