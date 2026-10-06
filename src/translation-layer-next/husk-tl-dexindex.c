/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "husk-tl-dexindex.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "husk-tl-internal.h"

typedef struct {
    const uint8_t *d;
    size_t size;
    uint32_t nstr, str_off, ntype, type_off, nproto, proto_off, nfield, field_off, nmeth, meth_off, nclass, class_off;
} dexfile;

typedef struct { int dex; uint32_t def; } cls_ref;

static dexfile g_dex[16];
static int g_ndex;
static cls_ref *g_tab;           /* open-addressed by hash of the descriptor */
static size_t g_tab_n;
static int g_classes;

static bool span(const dexfile *x, size_t o, size_t n) { return o <= x->size && n <= x->size - o; }
static uint32_t u32(const dexfile *x, size_t o) { uint32_t v = 0; if (span(x, o, 4)) memcpy(&v, x->d + o, 4); return v; }
static uint16_t u16(const dexfile *x, size_t o) { uint16_t v = 0; if (span(x, o, 2)) memcpy(&v, x->d + o, 2); return v; }

static uint32_t uleb(const dexfile *x, size_t *o)
{
    uint32_t r = 0;
    for (unsigned i = 0; i < 5; i++) {
        if (!span(x, *o, 1)) break;
        uint8_t b = x->d[(*o)++];
        if (i == 4 && (b & 0xf0)) break;
        r |= (uint32_t)(b & 0x7f) << (7 * i);
        if (!(b & 0x80)) return r;
    }
    *o = x->size + 1;
    return UINT32_MAX;
}

/* The UTF-8 bytes of string_ids[i], NUL-terminated inside the dex. */
static const char *str_of(const dexfile *x, uint32_t i)
{
    if (i >= x->nstr) return "";
    size_t o = u32(x, x->str_off + 4 * (size_t)i);
    uleb(x, &o);
    if (!span(x, o, 1)) return "";
    size_t remaining = x->size - o;
    if (!memchr(x->d + o, 0, remaining < 65536 ? remaining : 65536)) return "";
    return (const char *)x->d + o;
}
static const char *type_of(const dexfile *x, uint32_t t) { return t < x->ntype ? str_of(x, u32(x, x->type_off + 4 * (size_t)t)) : ""; }

static bool table_span(const dexfile *x, uint32_t off, uint32_t count, size_t stride)
{
    return (!count || (off >= 112 && off % 4 == 0))
        && span(x, off, (size_t)count * stride);
}

bool tl_dex_validate_bytes(const uint8_t *data, size_t size)
{
    if (!data || size < 112 || size > 256 * 1024 * 1024
        || memcmp(data, "dex\n", 4) || data[7] != 0) return false;
    dexfile x = { .d = data, .size = size };
    if (u32(&x, 0x20) != size || u32(&x, 0x24) != 112 || u32(&x, 0x28) != 0x12345678) return false;
    x.nstr = u32(&x, 0x38); x.str_off = u32(&x, 0x3c);
    x.ntype = u32(&x, 0x40); x.type_off = u32(&x, 0x44);
    x.nproto = u32(&x, 0x48); x.proto_off = u32(&x, 0x4c);
    x.nfield = u32(&x, 0x50); x.field_off = u32(&x, 0x54);
    x.nmeth = u32(&x, 0x58); x.meth_off = u32(&x, 0x5c);
    x.nclass = u32(&x, 0x60); x.class_off = u32(&x, 0x64);
    if (x.nstr > 1048576 || x.ntype > 65535 || x.nproto > 65535
        || x.nfield > 1048576 || x.nmeth > 1048576 || x.nclass > 262144
        || !table_span(&x, x.str_off, x.nstr, 4)
        || !table_span(&x, x.type_off, x.ntype, 4)
        || !table_span(&x, x.proto_off, x.nproto, 12)
        || !table_span(&x, x.field_off, x.nfield, 8)
        || !table_span(&x, x.meth_off, x.nmeth, 8)
        || !table_span(&x, x.class_off, x.nclass, 32)) return false;
    for (uint32_t i = 0; i < x.nstr; i++) {
        size_t off = u32(&x, x.str_off + (size_t)4 * i);
        if (off < 112 || !span(&x, off, 1)) return false;
        uleb(&x, &off);
        if (!span(&x, off, 1)) return false;
        size_t left = size - off;
        if (!memchr(data + off, 0, left < 65536 ? left : 65536)) return false;
    }
    for (uint32_t i = 0; i < x.ntype; i++)
        if (u32(&x, x.type_off + (size_t)4 * i) >= x.nstr) return false;
    for (uint32_t i = 0; i < x.nproto; i++) {
        size_t p = x.proto_off + (size_t)12 * i;
        if (u32(&x, p) >= x.nstr || u32(&x, p + 4) >= x.ntype) return false;
        uint32_t params = u32(&x, p + 8);
        if (params) {
            if (params % 4 || !span(&x, params, 4)) return false;
            uint32_t n = u32(&x, params);
            if (n > 65535 || !span(&x, (size_t)params + 4, (size_t)n * 2)) return false;
            for (uint32_t k = 0; k < n; k++)
                if (u16(&x, (size_t)params + 4 + (size_t)k * 2) >= x.ntype) return false;
        }
    }
    for (uint32_t i = 0; i < x.nfield; i++) {
        size_t p = x.field_off + (size_t)8 * i;
        if (u16(&x, p) >= x.ntype || u16(&x, p + 2) >= x.ntype || u32(&x, p + 4) >= x.nstr) return false;
    }
    for (uint32_t i = 0; i < x.nmeth; i++) {
        size_t p = x.meth_off + (size_t)8 * i;
        if (u16(&x, p) >= x.ntype || u16(&x, p + 2) >= x.nproto || u32(&x, p + 4) >= x.nstr) return false;
    }
    uint64_t member_total = 0;
    for (uint32_t i = 0; i < x.nclass; i++) {
        size_t p = x.class_off + (size_t)32 * i;
        uint32_t tid = u32(&x, p), sup = u32(&x, p + 8), cdata = u32(&x, p + 24);
        if (tid >= x.ntype || (sup != UINT32_MAX && sup >= x.ntype)) return false;
        if (!cdata) continue;
        size_t off = cdata;
        uint32_t counts[4];
        for (int k = 0; k < 4; k++) counts[k] = uleb(&x, &off);
        if (off > size || (uint64_t)counts[0] + counts[1] > x.nfield
            || (uint64_t)counts[2] + counts[3] > x.nmeth) return false;
        for (int group = 0; group < 4; group++) {
            member_total += counts[group];
            if (member_total > 1048576) return false;
            uint32_t idx = 0;
            for (uint32_t k = 0; k < counts[group]; k++) {
                uint32_t delta = uleb(&x, &off);
                if (delta > UINT32_MAX - idx) return false;
                idx += delta;
                (void)uleb(&x, &off);
                if (idx >= (group < 2 ? x.nfield : x.nmeth) || off > size) return false;
                if (group >= 2) {
                    uint32_t code = uleb(&x, &off);
                    if (off > size) return false;
                    if (code) {
                        if (code % 4 || !span(&x, code, 16)) return false;
                        uint32_t units = u32(&x, (size_t)code + 12);
                        if (!span(&x, (size_t)code + 16, (size_t)units * 2)
                            || u16(&x, (size_t)code + 2) > u16(&x, code)) return false;
                    }
                }
            }
        }
    }
    return true;
}

/* "Lcom/a/B;" -> "com/a/B" (compared in place; no copy). */
static bool desc_eq(const char *desc, const char *name)
{
    size_t n = strlen(name);
    return strlen(desc) == n + 2 && desc[0] == 'L'
        && !memcmp(desc + 1, name, n) && desc[1 + n] == ';';
}

static uint64_t hash_name(const char *s, size_t n)
{
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < n; i++) { h ^= (unsigned char)s[i]; h *= 1099511628211ull; }
    return h;
}

static uint64_t hash_desc(const char *desc) { return hash_name(desc + 1, strlen(desc) - 2); }

static void insert(int dex, uint32_t def, const char *desc)
{
    size_t len = strlen(desc);
    if (len < 3 || desc[0] != 'L' || desc[len - 1] != ';') return;
    size_t i = hash_desc(desc) & (g_tab_n - 1);
    while (g_tab[i].dex) i = (i + 1) & (g_tab_n - 1);
    g_tab[i].dex = dex + 1;
    g_tab[i].def = def;
}

int tl_dexidx_open(const char *apk_path)
{
    tl_zip z; char err[160];
    if (!tl_zip_open(&z, apk_path, err, sizeof(err))) return -1;
    size_t total = 0, bytes = 0;
    for (int i = 0; i < g_ndex; i++) { total += g_dex[i].nclass; bytes += g_dex[i].size; }
    for (int n = 1; n <= 16 && g_ndex < 16; n++) {
        char name[32];
        if (n == 1) snprintf(name, sizeof(name), "classes.dex"); else snprintf(name, sizeof(name), "classes%d.dex", n);
        const tl_zip_entry *e = tl_zip_find(&z, name);
        if (!e) { if (n > 1) break; continue; }
        const uint8_t *data; size_t len; bool owned;
        if (!tl_zip_data(&z, e, (size_t)1 << 28, &data, &len, &owned, err, sizeof(err))) goto bad;
        if (!tl_dex_validate_bytes(data, len) || bytes + len > (size_t)512 * 1024 * 1024) {
            if (owned) free((void *)data);
            goto bad;
        }
        if (!owned) {                         /* stored: it points into the APK mapping, which closing would unmap */
            uint8_t *copy = malloc(len);
            if (!copy) goto bad;
            memcpy(copy, data, len);
            data = copy;
        }
        dexfile *x = &g_dex[g_ndex++];
        x->d = data; x->size = len;
        memcpy(&x->nstr, data + 0x38, 4);  memcpy(&x->str_off, data + 0x3c, 4);
        memcpy(&x->ntype, data + 0x40, 4); memcpy(&x->type_off, data + 0x44, 4);
        memcpy(&x->nproto, data + 0x48, 4); memcpy(&x->proto_off, data + 0x4c, 4);
        memcpy(&x->nfield, data + 0x50, 4); memcpy(&x->field_off, data + 0x54, 4);
        memcpy(&x->nmeth, data + 0x58, 4); memcpy(&x->meth_off, data + 0x5c, 4);
        memcpy(&x->nclass, data + 0x60, 4); memcpy(&x->class_off, data + 0x64, 4);
        if (u32(x, 0x20) != len || u32(x, 0x24) != 112 || u32(x, 0x28) != 0x12345678
            || !span(x, x->str_off, (size_t)x->nstr * 4)
            || !span(x, x->type_off, (size_t)x->ntype * 4)
            || !span(x, x->proto_off, (size_t)x->nproto * 12)
            || !span(x, x->field_off, (size_t)x->nfield * 8)
            || !span(x, x->meth_off, (size_t)x->nmeth * 8)
            || !span(x, x->class_off, (size_t)x->nclass * 32)
            || x->nclass > 262144 || total + x->nclass > 262144) goto bad;
        total += x->nclass;
        bytes += len;
    }
    /* A zip kept open would pin the mapping; the dex bytes are copied or inflated, so close it. */
    tl_zip_close(&z);
    g_tab_n = 1;
    while (g_tab_n < total * 2 + 16) g_tab_n <<= 1;
    free(g_tab);
    g_tab = calloc(g_tab_n, sizeof(cls_ref));
    if (!g_tab) goto bad;
    for (int di = 0; di < g_ndex; di++) {
        dexfile *x = &g_dex[di];
        for (uint32_t c = 0; c < x->nclass; c++) {
            uint32_t tid = u32(x, x->class_off + 32u * c);
            insert(di, c, type_of(x, tid));
        }
    }
    g_classes = (int)total;
    return g_classes;
bad:
    tl_zip_close(&z);
    for (int i = 0; i < g_ndex; i++) free((void *)g_dex[i].d);
    memset(g_dex, 0, sizeof(g_dex));
    g_ndex = 0;
    free(g_tab); g_tab = NULL; g_tab_n = 0; g_classes = 0;
    return -1;
}

static const cls_ref *lookup(const char *name)
{
    if (!g_tab) return NULL;
    size_t i = hash_name(name, strlen(name)) & (g_tab_n - 1);
    while (g_tab[i].dex) {
        const dexfile *x = &g_dex[g_tab[i].dex - 1];
        uint32_t tid = u32(x, x->class_off + 32u * g_tab[i].def);
        if (desc_eq(type_of(x, tid), name)) return &g_tab[i];
        i = (i + 1) & (g_tab_n - 1);
    }
    return NULL;
}

bool tl_dexidx_has_class(const char *name) { return lookup(name) != NULL; }

const char *tl_dexidx_super(const char *name, char *buf, size_t n)
{
    const cls_ref *r = lookup(name);
    if (!r) return NULL;
    const dexfile *x = &g_dex[r->dex - 1];
    uint32_t sup = u32(x, x->class_off + 32u * r->def + 8);
    if (sup == 0xffffffffu) return NULL;
    const char *d = type_of(x, sup);
    size_t l = strlen(d);
    if (l < 3) return NULL;
    snprintf(buf, n, "%.*s", (int)(l - 2), d + 1);
    return buf;
}

/* "(Landroid/content/Context;)V" for proto_ids[i]. */
static void proto_sig(const dexfile *x, uint32_t pi, char *out, size_t n)
{
    if (!out || n == 0) return;
    out[0] = 0;
    if (n < 4 || pi >= x->nproto) return;
    size_t po = x->proto_off + (size_t)12 * pi;
    uint32_t ret = u32(x, po + 4), params = u32(x, po + 8);
    size_t k = 0;
    out[k++] = '(';
    if (params) {
        uint32_t cnt = u32(x, params);
        if (!span(x, (size_t)params + 4, (size_t)cnt * 2)) { out[0] = 0; return; }
        for (uint32_t i = 0; i < cnt; i++) {
            const char *t = type_of(x, u16(x, params + 4 + 2u * i));
            size_t l = strlen(t);
            if (k + l + 2 >= n) break;
            memcpy(out + k, t, l); k += l;
        }
    }
    out[k++] = ')';
    const char *rt = type_of(x, ret);
    size_t l = strlen(rt);
    if (k + l + 1 < n) { memcpy(out + k, rt, l); k += l; }
    out[k] = 0;
}

static bool scan_members(const char *cls, bool want_method, const char *name, const char *sig, bool *is_static, char *sig_out, size_t sig_n)
{
    const cls_ref *r = lookup(cls);
    if (!r) return false;
    const dexfile *x = &g_dex[r->dex - 1];
    uint32_t cdata = u32(x, x->class_off + 32u * r->def + 24);
    if (!cdata) return false;
    size_t o = cdata;
    uint32_t nsf = uleb(x, &o), nif = uleb(x, &o), ndm = uleb(x, &o), nvm = uleb(x, &o);
    uint32_t counts[4] = { nsf, nif, ndm, nvm };
    if (o > x->size || nsf > x->nfield || nif > x->nfield
        || ndm > x->nmeth || nvm > x->nmeth) return false;
    for (int group = 0; group < 4; group++) {
        bool method_group = group >= 2;
        uint32_t idx = 0;
        for (uint32_t i = 0; i < counts[group]; i++) {
            uint32_t delta = uleb(x, &o);
            if (delta > UINT32_MAX - idx) return false;
            idx += delta;
            uint32_t flags = uleb(x, &o);
            if (method_group) uleb(x, &o);              /* code_off */
            if (o > x->size || idx >= (method_group ? x->nmeth : x->nfield)) return false;
            if (method_group != want_method) continue;
            if (method_group) {
                size_t mo = x->meth_off + (size_t)8 * idx;
                uint32_t nameidx = u32(x, mo + 4); uint16_t protoidx = u16(x, mo + 2);
                if (strcmp(str_of(x, nameidx), name)) continue;
                if (sig && *sig) { char ps[512]; proto_sig(x, protoidx, ps, sizeof(ps)); if (strcmp(ps, sig)) continue; }
                if (sig_out) proto_sig(x, protoidx, sig_out, sig_n);
            } else {
                size_t fo = x->field_off + (size_t)8 * idx;
                uint16_t typeidx = u16(x, fo + 2); uint32_t nameidx = u32(x, fo + 4);
                if (strcmp(str_of(x, nameidx), name)) continue;
                if (sig && *sig && strcmp(type_of(x, typeidx), sig)) continue;
                if (sig_out) snprintf(sig_out, sig_n, "%s", type_of(x, typeidx));
            }
            if (is_static) *is_static = (flags & 8) != 0;
            return true;
        }
    }
    return false;
}

/* Split "(A B C)R" into parameter descriptors; returns the count and points `ret` at R. */
static int split_sig(const char *sig, const char **params, int *plen, int max, const char **ret)
{
    int n = 0;
    const char *p = sig;
    if (*p != '(') return -1;
    p++;
    while (*p && *p != ')' && n < max) {
        const char *start = p;
        while (*p == '[') p++;
        if (*p == 'L') { while (*p && *p != ';') p++; if (*p) p++; } else if (*p) p++;
        params[n] = start; plen[n] = (int)(p - start); n++;
    }
    if (*p != ')') return -1;
    *ret = p + 1;
    return n;
}
static bool is_object_desc(const char *d) { return d[0] == 'L' || d[0] == '['; }

/*
 * A method by name and parameters, tolerant the way Unity's reflection helper is: an argument given as
 * "Ljava/lang/Object;" (null, or an AndroidJavaObject) fits any object parameter, and any object return type
 * fits any other. Writes the declared signature to `out`.
 */
bool tl_dexidx_find_method_lenient(const char *cls, const char *name, const char *want, char *out, size_t n, bool *is_static)
{
    const cls_ref *r = lookup(cls);
    if (!r) return false;
    const dexfile *x = &g_dex[r->dex - 1];
    uint32_t cdata = u32(x, x->class_off + 32u * r->def + 24);
    if (!cdata) return false;
    const char *wp[40]; int wl[40]; const char *wret;
    int wn = split_sig(want, wp, wl, 40, &wret);
    if (wn < 0) return false;
    size_t o = cdata;
    uint32_t nsf = uleb(x, &o), nif = uleb(x, &o), ndm = uleb(x, &o), nvm = uleb(x, &o);
    uint32_t counts[4] = { nsf, nif, ndm, nvm };
    if (o > x->size || nsf > x->nfield || nif > x->nfield
        || ndm > x->nmeth || nvm > x->nmeth) return false;
    int best = -1;
    for (int group = 0; group < 4; group++) {
        uint32_t idx = 0;
        for (uint32_t i = 0; i < counts[group]; i++) {
            uint32_t delta = uleb(x, &o);
            if (delta > UINT32_MAX - idx) return false;
            idx += delta;
            uint32_t flags = uleb(x, &o);
            if (group >= 2) uleb(x, &o);
            if (o > x->size || idx >= (group >= 2 ? x->nmeth : x->nfield)) return false;
            if (group < 2) continue;
            size_t mo = x->meth_off + (size_t)8 * idx;
            if (strcmp(str_of(x, u32(x, mo + 4)), name)) continue;
            char ps[512]; proto_sig(x, u16(x, mo + 2), ps, sizeof(ps));
            const char *dp[40]; int dl[40]; const char *dret;
            int dn = split_sig(ps, dp, dl, 40, &dret);
            if (dn != wn) continue;
            /* An object argument fits any object parameter (a subclass, or Object for a null); the most exact fit wins. */
            bool ok = true; int exact = 0;
            for (int k = 0; k < dn && ok; k++) {
                bool same = dl[k] == wl[k] && !strncmp(dp[k], wp[k], (size_t)dl[k]);
                if (same) exact++;
                else ok = is_object_desc(dp[k]) && is_object_desc(wp[k]);
            }
            if (!ok) continue;
            if (!(is_object_desc(dret) && is_object_desc(wret)) && strcmp(dret, wret)) continue;
            if (exact > best) {
                best = exact;
                snprintf(out, n, "%s", ps);
                if (is_static) *is_static = (flags & 8) != 0;
            }
        }
    }
    return best >= 0;
}

bool tl_dexidx_declares_method(const char *cls, const char *name, const char *sig, bool *st) { return scan_members(cls, true, name, sig, st, NULL, 0); }
bool tl_dexidx_declares_field(const char *cls, const char *name, const char *sig, bool *st) { return scan_members(cls, false, name, sig, st, NULL, 0); }
bool tl_dexidx_field_sig(const char *cls, const char *name, char *out, size_t n) { return scan_members(cls, false, name, "", NULL, out, n); }
bool tl_dexidx_method_named(const char *cls, const char *name) { return scan_members(cls, true, name, "", NULL, NULL, 0); }
