#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <sys/utsname.h>

/*
 * GoldenGate (macOS 27 / 26B131) discrete-GPU Metal compatibility layer for AMDMTLBronzeDriver.
 *
 * Bridges two Apple-Silicon-only assumptions introduced in macOS 27 frameworks:
 *
 * 1. RenderBox non-TBDR (framebuffer-read) removal:
 *    - RB::RenderFrame::EncoderData & RB::Device::preload_uber_shader hardcode bit 15 (0x8000)
 *      of uint4 _shader_state[2] (has_fb_read = 1).
 *    - RB::Texture::make_descriptor omits MTLTextureUsageShaderRead (0x1) on RT textures.
 *    - RB::RenderQueue::encode no longer binds colorAttachments[0..2] to fragment texture
 *      slots 4..6 or emits memoryBarrierWithScope:MTLBarrierScopeRenderTargets.
 *    Stock 26B131 RenderBox/default.metallib retains the *_and_not_fb_read paths gated on
 *    _shader_state[2] bit 15, while GCN 1.0 libAMDIL902 exits with code 1 on air.render_target.
 *
 * 2. RenderBox & CoreImage Unified Memory (UMA) texture coherency removal:
 *    - macOS 27 RenderBox and CoreImage removed synchronizeResource: and allocate standalone
 *      CPU-readable textures with MTLStorageModeShared (0).
 *    - On discrete GCN 1.0 (AMDMTLBronzeDriver), standalone Shared/Managed textures live in
 *      VRAM + sysmem shadow; GPU writes read back as all-zeros via getBytes: unless flushed
 *      with MTLBlitCommandEncoder synchronizeResource: before commit (whereas Shared buffers,
 *      buffer-backed textures, and IOSurface textures are already coherent over PCIe GART).
 */

enum {
    RB_READ_COLOR = 1u << 0,
    RB_READ_COV   = 1u << 1,
    RB_READ_LAYER = 1u << 2,
};

typedef struct {
    uint8_t read_mask;
    uint8_t write_mask;
} RBPSOTag;

typedef struct {
    uintptr_t key;
    uint8_t   read_mask;
    uint8_t   write_mask;
    uint8_t   used;
} RBPSOEntry;

typedef struct {
    uintptr_t key;
    __unsafe_unretained id<MTLTexture> att[3];
    uint8_t   bound[3];
    uint8_t   cur_is_rb;
    uint8_t   cur_read;
    uint8_t   cur_write;
    uint8_t   dirty;
    uint8_t   used;
} RBEncEntry;

#define PSO_CAP 2048
#define PSO_MASK (PSO_CAP - 1)
#define ENC_CAP 128
#define ENC_MASK (ENC_CAP - 1)
#define CB_CAP 128
#define CB_MASK (CB_CAP - 1)
#define CB_SYNC_INLINE 16

typedef struct {
    uintptr_t key;
    const void *inline_tex[CB_SYNC_INLINE];
    const void **extra;
    uint16_t count;
    uint16_t extra_cap;
    uint8_t used;
} CBSyncEntry;

typedef struct {
    uintptr_t enc_key;
    uintptr_t cb_key;
    uint8_t used;
} SubEncEntry;

static os_unfair_lock g_pso_lock = OS_UNFAIR_LOCK_INIT;
static RBPSOEntry g_pso_tbl[PSO_CAP];
static _Atomic uint32_t g_pso_count = 0;

static os_unfair_lock g_enc_lock = OS_UNFAIR_LOCK_INIT;
static RBEncEntry g_enc_tbl[ENC_CAP];

static os_unfair_lock g_cb_lock = OS_UNFAIR_LOCK_INIT;
static CBSyncEntry g_cb_tbl[CB_CAP];
static _Atomic uint32_t g_cb_sync_count = 0;

static os_unfair_lock g_subenc_lock = OS_UNFAIR_LOCK_INIT;
static SubEncEntry g_subenc_tbl[ENC_CAP];

#ifdef GG_RB_SELFTEST
static _Atomic uint64_t g_uma_auto_sync_ops = 0;
#endif

static _Atomic uint32_t g_rb_lib_loaded = 0;
static _Atomic uint32_t g_bronze_hooked = 0;

static const void *kRBLibKey = &kRBLibKey;
static const void *kRBConstValsKey = &kRBConstValsKey;
static const void *kRBFnMaskKey = &kRBFnMaskKey;
static const void *kRBPSOSentinelKey = &kRBPSOSentinelKey;

static inline uint32_t ptr_hash(uintptr_t p) {
    p ^= p >> 16;
    p *= 0x45d9f3bu;
    p ^= p >> 16;
    return (uint32_t)p;
}

static void pso_table_put(uintptr_t key, uint8_t read_mask, uint8_t write_mask) {
    os_unfair_lock_lock(&g_pso_lock);
    uint32_t idx = ptr_hash(key) & PSO_MASK;
    for (uint32_t i = 0; i < PSO_CAP; i++) {
        uint32_t slot = (idx + i) & PSO_MASK;
        if (!g_pso_tbl[slot].used || g_pso_tbl[slot].key == key) {
            if (!g_pso_tbl[slot].used) {
                atomic_fetch_add_explicit(&g_pso_count, 1, memory_order_relaxed);
            }
            g_pso_tbl[slot].key = key;
            g_pso_tbl[slot].read_mask = read_mask;
            g_pso_tbl[slot].write_mask = write_mask;
            g_pso_tbl[slot].used = 1;
            break;
        }
    }
    os_unfair_lock_unlock(&g_pso_lock);
}

static BOOL pso_table_get(uintptr_t key, RBPSOTag *out) {
    if (atomic_load_explicit(&g_pso_count, memory_order_relaxed) == 0) {
        return NO;
    }
    BOOL found = NO;
    os_unfair_lock_lock(&g_pso_lock);
    uint32_t idx = ptr_hash(key) & PSO_MASK;
    for (uint32_t i = 0; i < PSO_CAP; i++) {
        uint32_t slot = (idx + i) & PSO_MASK;
        if (!g_pso_tbl[slot].used) {
            break;
        }
        if (g_pso_tbl[slot].key == key) {
            out->read_mask = g_pso_tbl[slot].read_mask;
            out->write_mask = g_pso_tbl[slot].write_mask;
            found = YES;
            break;
        }
    }
    os_unfair_lock_unlock(&g_pso_lock);
    return found;
}

static void pso_table_del(uintptr_t key) {
    os_unfair_lock_lock(&g_pso_lock);
    uint32_t idx = ptr_hash(key) & PSO_MASK;
    for (uint32_t i = 0; i < PSO_CAP; i++) {
        uint32_t slot = (idx + i) & PSO_MASK;
        if (!g_pso_tbl[slot].used) {
            break;
        }
        if (g_pso_tbl[slot].key == key) {
            uint32_t hole = slot;
            uint32_t cur = (hole + 1) & PSO_MASK;
            while (g_pso_tbl[cur].used) {
                uint32_t ideal = ptr_hash(g_pso_tbl[cur].key) & PSO_MASK;
                uint32_t dist_cur = (cur - ideal) & PSO_MASK;
                uint32_t dist_hole = (cur - hole) & PSO_MASK;
                if (dist_cur >= dist_hole) {
                    g_pso_tbl[hole] = g_pso_tbl[cur];
                    hole = cur;
                }
                cur = (cur + 1) & PSO_MASK;
            }
            g_pso_tbl[hole].used = 0;
            g_pso_tbl[hole].key = 0;
            atomic_fetch_sub_explicit(&g_pso_count, 1, memory_order_relaxed);
            break;
        }
    }
    os_unfair_lock_unlock(&g_pso_lock);
}

@interface GG_RBPSOSentinel : NSObject {
@public
    uintptr_t _key;
}
@end

@implementation GG_RBPSOSentinel
- (void)dealloc {
    if (_key) {
        pso_table_del(_key);
    }
}
@end

static void enc_table_put(uintptr_t key, id<MTLTexture> a0, id<MTLTexture> a1, id<MTLTexture> a2, uint8_t init_dirty) {
    os_unfair_lock_lock(&g_enc_lock);
    uint32_t idx = ptr_hash(key) & ENC_MASK;
    for (uint32_t i = 0; i < ENC_CAP; i++) {
        uint32_t slot = (idx + i) & ENC_MASK;
        if (!g_enc_tbl[slot].used || g_enc_tbl[slot].key == key) {
            memset(&g_enc_tbl[slot], 0, sizeof(RBEncEntry));
            g_enc_tbl[slot].key = key;
            g_enc_tbl[slot].att[0] = a0;
            g_enc_tbl[slot].att[1] = a1;
            g_enc_tbl[slot].att[2] = a2;
            g_enc_tbl[slot].dirty = init_dirty;
            g_enc_tbl[slot].used = 1;
            break;
        }
    }
    os_unfair_lock_unlock(&g_enc_lock);
}

static void enc_table_del(uintptr_t key) {
    os_unfair_lock_lock(&g_enc_lock);
    uint32_t idx = ptr_hash(key) & ENC_MASK;
    for (uint32_t i = 0; i < ENC_CAP; i++) {
        uint32_t slot = (idx + i) & ENC_MASK;
        if (!g_enc_tbl[slot].used) {
            break;
        }
        if (g_enc_tbl[slot].key == key) {
            uint32_t hole = slot;
            uint32_t cur = (hole + 1) & ENC_MASK;
            while (g_enc_tbl[cur].used) {
                uint32_t ideal = ptr_hash(g_enc_tbl[cur].key) & ENC_MASK;
                uint32_t dist_cur = (cur - ideal) & ENC_MASK;
                uint32_t dist_hole = (cur - hole) & ENC_MASK;
                if (dist_cur >= dist_hole) {
                    g_enc_tbl[hole] = g_enc_tbl[cur];
                    hole = cur;
                }
                cur = (cur + 1) & ENC_MASK;
            }
            g_enc_tbl[hole].used = 0;
            g_enc_tbl[hole].key = 0;
            break;
        }
    }
    os_unfair_lock_unlock(&g_enc_lock);
}

static RBEncEntry *enc_table_find_locked(uintptr_t key) {
    uint32_t idx = ptr_hash(key) & ENC_MASK;
    for (uint32_t i = 0; i < ENC_CAP; i++) {
        uint32_t slot = (idx + i) & ENC_MASK;
        if (!g_enc_tbl[slot].used) {
            return NULL;
        }
        if (g_enc_tbl[slot].key == key) {
            return &g_enc_tbl[slot];
        }
    }
    return NULL;
}

static void subenc_put(uintptr_t enc_key, uintptr_t cb_key) {
    os_unfair_lock_lock(&g_subenc_lock);
    uint32_t idx = ptr_hash(enc_key) & ENC_MASK;
    for (uint32_t i = 0; i < ENC_CAP; i++) {
        uint32_t slot = (idx + i) & ENC_MASK;
        if (!g_subenc_tbl[slot].used || g_subenc_tbl[slot].enc_key == enc_key) {
            g_subenc_tbl[slot].enc_key = enc_key;
            g_subenc_tbl[slot].cb_key = cb_key;
            g_subenc_tbl[slot].used = 1;
            break;
        }
    }
    os_unfair_lock_unlock(&g_subenc_lock);
}

static uintptr_t subenc_get(uintptr_t enc_key) {
    uintptr_t cb_key = 0;
    os_unfair_lock_lock(&g_subenc_lock);
    uint32_t idx = ptr_hash(enc_key) & ENC_MASK;
    for (uint32_t i = 0; i < ENC_CAP; i++) {
        uint32_t slot = (idx + i) & ENC_MASK;
        if (!g_subenc_tbl[slot].used) {
            break;
        }
        if (g_subenc_tbl[slot].enc_key == enc_key) {
            cb_key = g_subenc_tbl[slot].cb_key;
            break;
        }
    }
    os_unfair_lock_unlock(&g_subenc_lock);
    return cb_key;
}

static void subenc_del(uintptr_t enc_key) {
    os_unfair_lock_lock(&g_subenc_lock);
    uint32_t idx = ptr_hash(enc_key) & ENC_MASK;
    for (uint32_t i = 0; i < ENC_CAP; i++) {
        uint32_t slot = (idx + i) & ENC_MASK;
        if (!g_subenc_tbl[slot].used) {
            break;
        }
        if (g_subenc_tbl[slot].enc_key == enc_key) {
            uint32_t hole = slot;
            uint32_t cur = (hole + 1) & ENC_MASK;
            while (g_subenc_tbl[cur].used) {
                uint32_t ideal = ptr_hash(g_subenc_tbl[cur].enc_key) & ENC_MASK;
                uint32_t dist_cur = (cur - ideal) & ENC_MASK;
                uint32_t dist_hole = (cur - hole) & ENC_MASK;
                if (dist_cur >= dist_hole) {
                    g_subenc_tbl[hole] = g_subenc_tbl[cur];
                    hole = cur;
                }
                cur = (cur + 1) & ENC_MASK;
            }
            g_subenc_tbl[hole].used = 0;
            g_subenc_tbl[hole].enc_key = 0;
            g_subenc_tbl[hole].cb_key = 0;
            break;
        }
    }
    os_unfair_lock_unlock(&g_subenc_lock);
}

static inline id<MTLTexture> tex_sync_root(id<MTLTexture> tex) {
    if (!tex) return nil;
    id<MTLTexture> parent = tex.parentTexture;
    while (parent) {
        tex = parent;
        parent = tex.parentTexture;
    }
    MTLStorageMode sm = tex.storageMode;
    if (sm != MTLStorageModeShared && sm != MTLStorageModeManaged) {
        return nil;
    }
    if (tex.iosurface != NULL || tex.buffer != nil || tex.heap != nil) {
        return nil;
    }
    return tex;
}

static void cb_sync_mark_tex(uintptr_t cb_key, id<MTLTexture> tex) {
    if (!cb_key) return;
    id<MTLTexture> root = tex_sync_root(tex);
    if (!root) return;
    const void *raw = (__bridge const void *)root;

    os_unfair_lock_lock(&g_cb_lock);
    uint32_t idx = ptr_hash(cb_key) & CB_MASK;
    for (uint32_t i = 0; i < CB_CAP; i++) {
        uint32_t slot = (idx + i) & CB_MASK;
        CBSyncEntry *e = &g_cb_tbl[slot];
        if (!e->used) {
            memset(e, 0, sizeof(CBSyncEntry));
            e->key = cb_key;
            e->used = 1;
            e->inline_tex[0] = CFRetain(raw);
            e->count = 1;
            atomic_fetch_add_explicit(&g_cb_sync_count, 1, memory_order_relaxed);
            break;
        }
        if (e->key == cb_key) {
            uint16_t inline_n = e->count < CB_SYNC_INLINE ? e->count : CB_SYNC_INLINE;
            for (uint16_t j = 0; j < inline_n; j++) {
                if (e->inline_tex[j] == raw) {
                    os_unfair_lock_unlock(&g_cb_lock);
                    return;
                }
            }
            for (uint16_t j = CB_SYNC_INLINE; j < e->count; j++) {
                if (e->extra[j - CB_SYNC_INLINE] == raw) {
                    os_unfair_lock_unlock(&g_cb_lock);
                    return;
                }
            }
            if (e->count < CB_SYNC_INLINE) {
                e->inline_tex[e->count++] = CFRetain(raw);
            } else {
                uint16_t ex_idx = (uint16_t)(e->count - CB_SYNC_INLINE);
                if (ex_idx >= e->extra_cap) {
                    uint16_t new_cap = e->extra_cap ? (uint16_t)(e->extra_cap * 2) : 32;
                    const void **nb = (const void **)realloc(e->extra, (size_t)new_cap * sizeof(const void *));
                    if (!nb) break;
                    e->extra = nb;
                    e->extra_cap = new_cap;
                }
                e->extra[ex_idx] = CFRetain(raw);
                e->count++;
            }
            break;
        }
    }
    os_unfair_lock_unlock(&g_cb_lock);
}

static void cb_sync_clear_tex(uintptr_t cb_key, id<MTLTexture> tex) {
    if (!cb_key || atomic_load_explicit(&g_cb_sync_count, memory_order_relaxed) == 0) {
        return;
    }
    id<MTLTexture> root = tex_sync_root(tex);
    if (!root) return;
    const void *raw = (__bridge const void *)root;
    const void *to_release = NULL;

    os_unfair_lock_lock(&g_cb_lock);
    uint32_t idx = ptr_hash(cb_key) & CB_MASK;
    for (uint32_t i = 0; i < CB_CAP; i++) {
        uint32_t slot = (idx + i) & CB_MASK;
        CBSyncEntry *e = &g_cb_tbl[slot];
        if (!e->used) break;
        if (e->key == cb_key) {
            uint16_t n = e->count;
            for (uint16_t j = 0; j < n; j++) {
                const void *cur = (j < CB_SYNC_INLINE) ? e->inline_tex[j] : e->extra[j - CB_SYNC_INLINE];
                if (cur == raw) {
                    to_release = cur;
                    uint16_t last = (uint16_t)(n - 1);
                    if (j != last) {
                        const void *last_val = (last < CB_SYNC_INLINE) ? e->inline_tex[last] : e->extra[last - CB_SYNC_INLINE];
                        if (j < CB_SYNC_INLINE) {
                            e->inline_tex[j] = last_val;
                        } else {
                            e->extra[j - CB_SYNC_INLINE] = last_val;
                        }
                    }
                    e->count = last;
                    break;
                }
            }
            break;
        }
    }
    os_unfair_lock_unlock(&g_cb_lock);

    if (to_release) {
        CFRelease(to_release);
    }
}

static BOOL cb_sync_pop(uintptr_t cb_key, CBSyncEntry *out) {
    if (!cb_key || atomic_load_explicit(&g_cb_sync_count, memory_order_relaxed) == 0) {
        return NO;
    }
    BOOL found = NO;
    os_unfair_lock_lock(&g_cb_lock);
    uint32_t idx = ptr_hash(cb_key) & CB_MASK;
    for (uint32_t i = 0; i < CB_CAP; i++) {
        uint32_t slot = (idx + i) & CB_MASK;
        if (!g_cb_tbl[slot].used) {
            break;
        }
        if (g_cb_tbl[slot].key == cb_key) {
            *out = g_cb_tbl[slot];
            found = YES;
            uint32_t hole = slot;
            uint32_t cur = (hole + 1) & CB_MASK;
            while (g_cb_tbl[cur].used) {
                uint32_t ideal = ptr_hash(g_cb_tbl[cur].key) & CB_MASK;
                uint32_t dist_cur = (cur - ideal) & CB_MASK;
                uint32_t dist_hole = (cur - hole) & CB_MASK;
                if (dist_cur >= dist_hole) {
                    g_cb_tbl[hole] = g_cb_tbl[cur];
                    hole = cur;
                }
                cur = (cur + 1) & CB_MASK;
            }
            memset(&g_cb_tbl[hole], 0, sizeof(CBSyncEntry));
            atomic_fetch_sub_explicit(&g_cb_sync_count, 1, memory_order_relaxed);
            break;
        }
    }
    os_unfair_lock_unlock(&g_cb_lock);
    return found;
}

static void cb_sync_release_entry(CBSyncEntry *e) {
    for (uint16_t i = 0; i < e->count; i++) {
        const void *p = (i < CB_SYNC_INLINE) ? e->inline_tex[i] : e->extra[i - CB_SYNC_INLINE];
        if (p) CFRelease(p);
    }
    if (e->extra) {
        free(e->extra);
        e->extra = NULL;
    }
    e->count = 0;
}

static void cb_sync_mark_rpd(uintptr_t cb_key, MTLRenderPassDescriptor *rpd) {
    if (!rpd) return;
    MTLRenderPassColorAttachmentDescriptorArray *atts = rpd.colorAttachments;
    for (NSUInteger i = 0; i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *a = atts[i];
        if (!a || a.storeAction == MTLStoreActionDontCare) continue;
        if (a.texture) cb_sync_mark_tex(cb_key, a.texture);
        if (a.resolveTexture) cb_sync_mark_tex(cb_key, a.resolveTexture);
    }
    MTLRenderPassDepthAttachmentDescriptor *da = rpd.depthAttachment;
    if (da && da.storeAction != MTLStoreActionDontCare) {
        if (da.texture) cb_sync_mark_tex(cb_key, da.texture);
        if (da.resolveTexture) cb_sync_mark_tex(cb_key, da.resolveTexture);
    }
    MTLRenderPassStencilAttachmentDescriptor *sa = rpd.stencilAttachment;
    if (sa && sa.storeAction != MTLStoreActionDontCare) {
        if (sa.texture) cb_sync_mark_tex(cb_key, sa.texture);
        if (sa.resolveTexture) cb_sync_mark_tex(cb_key, sa.resolveTexture);
    }
}

static BOOL is_color_pixel_format(MTLPixelFormat fmt) {
    switch (fmt) {
        case MTLPixelFormatInvalid:
        case MTLPixelFormatDepth16Unorm:
        case MTLPixelFormatDepth32Float:
        case MTLPixelFormatStencil8:
        case MTLPixelFormatDepth24Unorm_Stencil8:
        case MTLPixelFormatDepth32Float_Stencil8:
        case MTLPixelFormatX32_Stencil8:
        case MTLPixelFormatX24_Stencil8:
            return NO;
        default:
            return YES;
    }
}

static MTLTextureDescriptor *patch_rt_descriptor(MTLTextureDescriptor *desc) {
    if (!desc) return desc;
    MTLTextureUsage u = desc.usage;
    if ((u & MTLTextureUsageRenderTarget) &&
        !(u & MTLTextureUsageShaderRead) &&
        desc.storageMode != MTLStorageModeMemoryless &&
        desc.textureType == MTLTextureType2D &&
        desc.sampleCount <= 1 &&
        is_color_pixel_format(desc.pixelFormat)) {
        MTLTextureDescriptor *copy = [desc copy];
        copy.usage = u | MTLTextureUsageShaderRead;
        return copy;
    }
    return desc;
}

static BOOL device_needs_rb_fix(id dev) {
    if (!dev) return NO;
    SEL sel = @selector(isFramebufferReadSupported);
    if ([dev respondsToSelector:sel]) {
        BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))[dev methodForSelector:sel];
        return !fn(dev, sel);
    }
    return YES;
}

static uint8_t compute_rb_read_mask(NSString *fnName, const uint32_t v[4]) {
    uint8_t mask = 0;
    uint32_t fmt = v[2];
    uint32_t derived = v[3];
    if (derived & 0x20u) {
        mask |= RB_READ_COLOR;
        if (fmt & 0x4000u) {
            mask |= RB_READ_LAYER;
        }
    }
    if (derived & 0x40u) {
        mask |= RB_READ_COV;
    }
    if (fnName) {
        if ([fnName rangeOfString:@"spill"].location != NSNotFound ||
            [fnName rangeOfString:@"uber"].location != NSNotFound) {
            mask |= (RB_READ_COLOR | RB_READ_COV | RB_READ_LAYER);
        } else if ([fnName rangeOfString:@"filter_blur"].location != NSNotFound) {
            mask |= (RB_READ_COLOR | RB_READ_COV);
        }
    }
    return mask;
}

static uint8_t compute_pso_write_mask(MTLRenderPipelineDescriptor *desc) {
    uint8_t w = 0;
    if (!desc) return 0x7;
    MTLRenderPipelineColorAttachmentDescriptorArray *atts = desc.colorAttachments;
    for (NSUInteger i = 0; i < 3; i++) {
        MTLRenderPipelineColorAttachmentDescriptor *a = atts[i];
        if (a && a.pixelFormat != MTLPixelFormatInvalid && a.writeMask != MTLColorWriteMaskNone) {
            w |= (uint8_t)(1u << i);
        }
    }
    return w;
}

static void tag_pso_if_rb(id<MTLRenderPipelineState> pso, MTLRenderPipelineDescriptor *desc) {
    if (!pso || !desc) return;
    id<MTLFunction> frag = desc.fragmentFunction;
    if (!frag) return;
    NSNumber *maskNum = objc_getAssociatedObject(frag, kRBFnMaskKey);
    if (!maskNum) return;

    uint8_t read_mask = (uint8_t)(maskNum.unsignedIntValue & 0x7u);
    uint8_t write_mask = compute_pso_write_mask(desc);
    uintptr_t key = (uintptr_t)(__bridge void *)pso;
    pso_table_put(key, read_mask, write_mask);

    GG_RBPSOSentinel *s = [GG_RBPSOSentinel new];
    s->_key = key;
    objc_setAssociatedObject(pso, kRBPSOSentinelKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/* Original IMP pointers */
static id (*orig_newLibraryWithURL)(id, SEL, NSURL *, NSError **) = NULL;
static id (*orig_dev_newTextureWithDesc)(id, SEL, MTLTextureDescriptor *) = NULL;
static id (*orig_dev_newTextureWithIOSurface)(id, SEL, MTLTextureDescriptor *, IOSurfaceRef, NSUInteger) = NULL;
static id (*orig_buf_newTextureWithDesc)(id, SEL, MTLTextureDescriptor *, NSUInteger, NSUInteger) = NULL;
static id (*orig_heap_newTextureWithDesc)(id, SEL, MTLTextureDescriptor *) = NULL;
static id (*orig_heap_newTextureWithDescOff)(id, SEL, MTLTextureDescriptor *, NSUInteger) = NULL;

static void (*orig_setConstantValue)(id, SEL, const void *, MTLDataType, NSUInteger) = NULL;
static id (*orig_cv_copyWithZone)(id, SEL, NSZone *) = NULL;

static id (*orig_newFnWithDesc_err)(id, SEL, MTLFunctionDescriptor *, NSError **) = NULL;
static void (*orig_newFnWithDesc_cb)(id, SEL, MTLFunctionDescriptor *, void (^)(id<MTLFunction>, NSError *)) = NULL;
static id (*orig_newFnWithName_cv_err)(id, SEL, NSString *, MTLFunctionConstantValues *, NSError **) = NULL;
static void (*orig_newFnWithName_cv_cb)(id, SEL, NSString *, MTLFunctionConstantValues *, void (^)(id<MTLFunction>, NSError *)) = NULL;

static id (*orig_newPSO_err)(id, SEL, MTLRenderPipelineDescriptor *, NSError **) = NULL;
static id (*orig_newPSO_opt_ref_err)(id, SEL, MTLRenderPipelineDescriptor *, MTLPipelineOption, MTLAutoreleasedRenderPipelineReflection *, NSError **) = NULL;
static void (*orig_newPSO_cb)(id, SEL, MTLRenderPipelineDescriptor *, void (^)(id<MTLRenderPipelineState>, NSError *)) = NULL;
static void (*orig_newPSO_opt_cb)(id, SEL, MTLRenderPipelineDescriptor *, MTLPipelineOption, void (^)(id<MTLRenderPipelineState>, MTLRenderPipelineReflection *, NSError *)) = NULL;

static id (*orig_renderCmdEncoder)(__unsafe_unretained id, SEL, __unsafe_unretained MTLRenderPassDescriptor *) = NULL;
static id (*orig_blitCmdEncoder)(__unsafe_unretained id, SEL) = NULL;
static id (*orig_compCmdEncoder)(__unsafe_unretained id, SEL) = NULL;
static id (*orig_compCmdEncoderDisp)(__unsafe_unretained id, SEL, MTLDispatchType) = NULL;
static void (*orig_cb_commit)(__unsafe_unretained id, SEL) = NULL;
static void (*orig_cb_dealloc)(__unsafe_unretained id, SEL) = NULL;

static void (*orig_blit_syncRes)(__unsafe_unretained id, SEL, __unsafe_unretained id<MTLResource>) = NULL;
static void (*orig_blit_syncTex)(__unsafe_unretained id, SEL, __unsafe_unretained id<MTLTexture>, NSUInteger, NSUInteger) = NULL;
static void (*orig_blit_copyTexOrigin)(__unsafe_unretained id, SEL, __unsafe_unretained id<MTLTexture>, NSUInteger, NSUInteger, MTLOrigin, MTLSize, __unsafe_unretained id<MTLTexture>, NSUInteger, NSUInteger, MTLOrigin) = NULL;
static void (*orig_blit_copyTexSlices)(__unsafe_unretained id, SEL, __unsafe_unretained id<MTLTexture>, NSUInteger, NSUInteger, __unsafe_unretained id<MTLTexture>, NSUInteger, NSUInteger, NSUInteger, NSUInteger) = NULL;
static void (*orig_blit_copyBufToTex)(__unsafe_unretained id, SEL, __unsafe_unretained id<MTLBuffer>, NSUInteger, NSUInteger, NSUInteger, MTLSize, __unsafe_unretained id<MTLTexture>, NSUInteger, NSUInteger, MTLOrigin) = NULL;
static void (*orig_blit_copyBufToTexOpts)(__unsafe_unretained id, SEL, __unsafe_unretained id<MTLBuffer>, NSUInteger, NSUInteger, NSUInteger, MTLSize, __unsafe_unretained id<MTLTexture>, NSUInteger, NSUInteger, MTLOrigin, MTLBlitOption) = NULL;
static void (*orig_blit_genMips)(__unsafe_unretained id, SEL, __unsafe_unretained id<MTLTexture>) = NULL;
static void (*orig_blit_endEncoding)(__unsafe_unretained id, SEL) = NULL;
static void (*orig_blit_dealloc)(__unsafe_unretained id, SEL) = NULL;

static void (*orig_comp_setTex)(__unsafe_unretained id, SEL, __unsafe_unretained id<MTLTexture>, NSUInteger) = NULL;
static void (*orig_comp_setTexRange)(__unsafe_unretained id, SEL, const __unsafe_unretained id<MTLTexture> *, NSRange) = NULL;
static void (*orig_comp_endEncoding)(__unsafe_unretained id, SEL) = NULL;
static void (*orig_comp_dealloc)(__unsafe_unretained id, SEL) = NULL;

static void (*orig_setPSO)(__unsafe_unretained id, SEL, __unsafe_unretained id<MTLRenderPipelineState>) = NULL;
static void (*orig_setFragTex)(__unsafe_unretained id, SEL, __unsafe_unretained id<MTLTexture>, NSUInteger) = NULL;
static void (*orig_memBarrier)(__unsafe_unretained id, SEL, MTLBarrierScope, MTLRenderStages, MTLRenderStages) = NULL;
static void (*orig_endEncoding)(__unsafe_unretained id, SEL) = NULL;
static void (*orig_enc_dealloc)(__unsafe_unretained id, SEL) = NULL;

static void (*orig_draw_v)(__unsafe_unretained id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger) = NULL;
static void (*orig_draw_vi)(__unsafe_unretained id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger, NSUInteger) = NULL;
static void (*orig_draw_vib)(__unsafe_unretained id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger, NSUInteger, NSUInteger) = NULL;
static void (*orig_draw_ind)(__unsafe_unretained id, SEL, MTLPrimitiveType, __unsafe_unretained id<MTLBuffer>, NSUInteger) = NULL;
static void (*orig_drawIdx)(__unsafe_unretained id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, __unsafe_unretained id<MTLBuffer>, NSUInteger) = NULL;
static void (*orig_drawIdx_i)(__unsafe_unretained id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, __unsafe_unretained id<MTLBuffer>, NSUInteger, NSUInteger) = NULL;
static void (*orig_drawIdx_ivb)(__unsafe_unretained id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, __unsafe_unretained id<MTLBuffer>, NSUInteger, NSUInteger, NSInteger, NSUInteger) = NULL;
static void (*orig_drawIdx_ind)(__unsafe_unretained id, SEL, MTLPrimitiveType, MTLIndexType, __unsafe_unretained id<MTLBuffer>, NSUInteger, __unsafe_unretained id<MTLBuffer>, NSUInteger) = NULL;

static void install_bronze_hooks(void);

/* Hook implementations */

static id hook_newLibraryWithURL(id self, SEL _cmd, NSURL *url, NSError **error) {
    id lib = orig_newLibraryWithURL(self, _cmd, url, error);
    if (lib && url) {
        NSString *path = url.path;
        if (path && [path containsString:@"RenderBox.framework"] && device_needs_rb_fix(self)) {
            install_bronze_hooks();
            objc_setAssociatedObject(lib, kRBLibKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            atomic_store_explicit(&g_rb_lib_loaded, 1, memory_order_release);
        }
    }
    return lib;
}

static id hook_dev_newTextureWithDesc(id self, SEL _cmd, MTLTextureDescriptor *desc) {
    return orig_dev_newTextureWithDesc(self, _cmd, patch_rt_descriptor(desc));
}

static id hook_dev_newTextureWithIOSurface(id self, SEL _cmd, MTLTextureDescriptor *desc, IOSurfaceRef surf, NSUInteger plane) {
    return orig_dev_newTextureWithIOSurface(self, _cmd, patch_rt_descriptor(desc), surf, plane);
}

static id hook_buf_newTextureWithDesc(id self, SEL _cmd, MTLTextureDescriptor *desc, NSUInteger offset, NSUInteger bpr) {
    return orig_buf_newTextureWithDesc(self, _cmd, patch_rt_descriptor(desc), offset, bpr);
}

static id hook_heap_newTextureWithDesc(id self, SEL _cmd, MTLTextureDescriptor *desc) {
    return orig_heap_newTextureWithDesc(self, _cmd, patch_rt_descriptor(desc));
}

static id hook_heap_newTextureWithDescOff(id self, SEL _cmd, MTLTextureDescriptor *desc, NSUInteger offset) {
    return orig_heap_newTextureWithDescOff(self, _cmd, patch_rt_descriptor(desc), offset);
}

static void hook_setConstantValue(id self, SEL _cmd, const void *value, MTLDataType type, NSUInteger index) {
    if (type == MTLDataTypeUInt4 && index == 0 && value != NULL) {
        NSData *d = [NSData dataWithBytes:value length:16];
        objc_setAssociatedObject(self, kRBConstValsKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    orig_setConstantValue(self, _cmd, value, type, index);
}

static id hook_cv_copyWithZone(id self, SEL _cmd, NSZone *zone) {
    id copy = orig_cv_copyWithZone(self, _cmd, zone);
    if (copy) {
        NSData *d = objc_getAssociatedObject(self, kRBConstValsKey);
        if (d) {
            objc_setAssociatedObject(copy, kRBConstValsKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return copy;
}

static MTLFunctionConstantValues *patch_rb_const_values(MTLFunctionConstantValues *cv, NSString *fnName, BOOL *outIsRB, uint8_t *outReadMask) {
    *outIsRB = NO;
    *outReadMask = 0;
    if (!cv) return cv;
    NSData *d = objc_getAssociatedObject(cv, kRBConstValsKey);
    if (!d || d.length != 16) return cv;

    uint32_t v[4];
    memcpy(v, d.bytes, 16);
    *outIsRB = YES;
    *outReadMask = compute_rb_read_mask(fnName, v);

    if (v[2] & 0x8000u) {
        v[2] &= ~0x8000u;
        MTLFunctionConstantValues *cloned = [cv copy];
        orig_setConstantValue(cloned, @selector(setConstantValue:type:atIndex:), v, MTLDataTypeUInt4, 0);
        NSData *nd = [NSData dataWithBytes:v length:16];
        objc_setAssociatedObject(cloned, kRBConstValsKey, nd, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return cloned;
    }
    return cv;
}

static void tag_rb_function(id<MTLFunction> fn, uint8_t readMask) {
    if (fn && fn.functionType == MTLFunctionTypeFragment) {
        objc_setAssociatedObject(fn, kRBFnMaskKey, @(readMask | 0x80u), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static id hook_newFnWithDesc_err(id self, SEL _cmd, MTLFunctionDescriptor *desc, NSError **error) {
    if (desc && objc_getAssociatedObject(self, kRBLibKey)) {
        BOOL isRB = NO;
        uint8_t readMask = 0;
        MTLFunctionConstantValues *origCV = desc.constantValues;
        MTLFunctionConstantValues *newCV = patch_rb_const_values(origCV, desc.name, &isRB, &readMask);
        if (isRB) {
            MTLFunctionDescriptor *useDesc = desc;
            if (newCV != origCV) {
                useDesc = [desc copy];
                useDesc.constantValues = newCV;
                useDesc.binaryArchives = nil;
            }
            id<MTLFunction> fn = orig_newFnWithDesc_err(self, _cmd, useDesc, error);
            tag_rb_function(fn, readMask);
            return fn;
        }
    }
    return orig_newFnWithDesc_err(self, _cmd, desc, error);
}

static void hook_newFnWithDesc_cb(id self, SEL _cmd, MTLFunctionDescriptor *desc, void (^cb)(id<MTLFunction>, NSError *)) {
    if (desc && objc_getAssociatedObject(self, kRBLibKey)) {
        BOOL isRB = NO;
        uint8_t readMask = 0;
        MTLFunctionConstantValues *origCV = desc.constantValues;
        MTLFunctionConstantValues *newCV = patch_rb_const_values(origCV, desc.name, &isRB, &readMask);
        if (isRB) {
            MTLFunctionDescriptor *useDesc = desc;
            if (newCV != origCV) {
                useDesc = [desc copy];
                useDesc.constantValues = newCV;
                useDesc.binaryArchives = nil;
            }
            orig_newFnWithDesc_cb(self, _cmd, useDesc, ^(id<MTLFunction> fn, NSError *err) {
                tag_rb_function(fn, readMask);
                if (cb) cb(fn, err);
            });
            return;
        }
    }
    orig_newFnWithDesc_cb(self, _cmd, desc, cb);
}

static id hook_newFnWithName_cv_err(id self, SEL _cmd, NSString *name, MTLFunctionConstantValues *cv, NSError **error) {
    if (cv && objc_getAssociatedObject(self, kRBLibKey)) {
        BOOL isRB = NO;
        uint8_t readMask = 0;
        MTLFunctionConstantValues *newCV = patch_rb_const_values(cv, name, &isRB, &readMask);
        if (isRB) {
            id<MTLFunction> fn = orig_newFnWithName_cv_err(self, _cmd, name, newCV, error);
            tag_rb_function(fn, readMask);
            return fn;
        }
    }
    return orig_newFnWithName_cv_err(self, _cmd, name, cv, error);
}

static void hook_newFnWithName_cv_cb(id self, SEL _cmd, NSString *name, MTLFunctionConstantValues *cv, void (^cb)(id<MTLFunction>, NSError *)) {
    if (cv && objc_getAssociatedObject(self, kRBLibKey)) {
        BOOL isRB = NO;
        uint8_t readMask = 0;
        MTLFunctionConstantValues *newCV = patch_rb_const_values(cv, name, &isRB, &readMask);
        if (isRB) {
            orig_newFnWithName_cv_cb(self, _cmd, name, newCV, ^(id<MTLFunction> fn, NSError *err) {
                tag_rb_function(fn, readMask);
                if (cb) cb(fn, err);
            });
            return;
        }
    }
    orig_newFnWithName_cv_cb(self, _cmd, name, cv, cb);
}

static id hook_newPSO_err(id self, SEL _cmd, MTLRenderPipelineDescriptor *desc, NSError **error) {
    id pso = orig_newPSO_err(self, _cmd, desc, error);
    tag_pso_if_rb(pso, desc);
    return pso;
}

static id hook_newPSO_opt_ref_err(id self, SEL _cmd, MTLRenderPipelineDescriptor *desc, MTLPipelineOption opts, MTLAutoreleasedRenderPipelineReflection *refl, NSError **error) {
    id pso = orig_newPSO_opt_ref_err(self, _cmd, desc, opts, refl, error);
    tag_pso_if_rb(pso, desc);
    return pso;
}

static void hook_newPSO_cb(id self, SEL _cmd, MTLRenderPipelineDescriptor *desc, void (^cb)(id<MTLRenderPipelineState>, NSError *)) {
    MTLRenderPipelineDescriptor *dcopy = (desc && desc.fragmentFunction && objc_getAssociatedObject(desc.fragmentFunction, kRBFnMaskKey)) ? [desc copy] : nil;
    if (!dcopy) {
        orig_newPSO_cb(self, _cmd, desc, cb);
        return;
    }
    orig_newPSO_cb(self, _cmd, desc, ^(id<MTLRenderPipelineState> pso, NSError *err) {
        tag_pso_if_rb(pso, dcopy);
        if (cb) cb(pso, err);
    });
}

static void hook_newPSO_opt_cb(id self, SEL _cmd, MTLRenderPipelineDescriptor *desc, MTLPipelineOption opts, void (^cb)(id<MTLRenderPipelineState>, MTLRenderPipelineReflection *, NSError *)) {
    MTLRenderPipelineDescriptor *dcopy = (desc && desc.fragmentFunction && objc_getAssociatedObject(desc.fragmentFunction, kRBFnMaskKey)) ? [desc copy] : nil;
    if (!dcopy) {
        orig_newPSO_opt_cb(self, _cmd, desc, opts, cb);
        return;
    }
    orig_newPSO_opt_cb(self, _cmd, desc, opts, ^(id<MTLRenderPipelineState> pso, MTLRenderPipelineReflection *refl, NSError *err) {
        tag_pso_if_rb(pso, dcopy);
        if (cb) cb(pso, refl, err);
    });
}

static id hook_renderCmdEncoder(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained MTLRenderPassDescriptor *rpd) {
    id enc = orig_renderCmdEncoder(self, _cmd, rpd);
    if (enc && rpd) {
        cb_sync_mark_rpd((uintptr_t)(__bridge void *)self, rpd);
        if (atomic_load_explicit(&g_rb_lib_loaded, memory_order_relaxed) != 0) {
            MTLRenderPassColorAttachmentDescriptorArray *atts = rpd.colorAttachments;
            id<MTLTexture> a0 = atts[0] ? atts[0].texture : nil;
            id<MTLTexture> a1 = atts[1] ? atts[1].texture : nil;
            id<MTLTexture> a2 = atts[2] ? atts[2].texture : nil;
            if (a0 || a1 || a2) {
                /* AMD GCN CMASK fast-clear requires a render-target barrier to expand before shader reads. */
                uint8_t init_dirty = 0;
                if (a0 && atts[0].loadAction == MTLLoadActionClear) init_dirty |= RB_READ_COLOR;
                if (a1 && atts[1].loadAction == MTLLoadActionClear) init_dirty |= RB_READ_COV;
                if (a2 && atts[2].loadAction == MTLLoadActionClear) init_dirty |= RB_READ_LAYER;
                enc_table_put((uintptr_t)(__bridge void *)enc, a0, a1, a2, init_dirty);
            }
        }
    }
    return enc;
}

static id hook_blitCmdEncoder(__unsafe_unretained id self, SEL _cmd) {
    id enc = orig_blitCmdEncoder(self, _cmd);
    if (enc) {
        subenc_put((uintptr_t)(__bridge void *)enc, (uintptr_t)(__bridge void *)self);
    }
    return enc;
}

static id hook_compCmdEncoder(__unsafe_unretained id self, SEL _cmd) {
    id enc = orig_compCmdEncoder(self, _cmd);
    if (enc) {
        subenc_put((uintptr_t)(__bridge void *)enc, (uintptr_t)(__bridge void *)self);
    }
    return enc;
}

static id hook_compCmdEncoderDisp(__unsafe_unretained id self, SEL _cmd, MTLDispatchType dt) {
    id enc = orig_compCmdEncoderDisp(self, _cmd, dt);
    if (enc) {
        subenc_put((uintptr_t)(__bridge void *)enc, (uintptr_t)(__bridge void *)self);
    }
    return enc;
}

static void hook_cb_commit(__unsafe_unretained id self, SEL _cmd) {
    CBSyncEntry entry;
    if (cb_sync_pop((uintptr_t)(__bridge void *)self, &entry)) {
        if (entry.count > 0 && orig_blitCmdEncoder && orig_blit_syncRes && orig_blit_endEncoding) {
            MTLCommandBufferStatus st = [(id<MTLCommandBuffer>)self status];
            if (st == MTLCommandBufferStatusNotEnqueued || st == MTLCommandBufferStatusEnqueued) {
                @autoreleasepool {
                    id blit = orig_blitCmdEncoder(self, @selector(blitCommandEncoder));
                    if (blit) {
                        for (uint16_t i = 0; i < entry.count; i++) {
                            const void *p = (i < CB_SYNC_INLINE) ? entry.inline_tex[i] : entry.extra[i - CB_SYNC_INLINE];
                            if (p) {
                                orig_blit_syncRes(blit, @selector(synchronizeResource:), (__bridge id<MTLResource>)p);
#ifdef GG_RB_SELFTEST
                                atomic_fetch_add_explicit(&g_uma_auto_sync_ops, 1, memory_order_relaxed);
#endif
                            }
                        }
                        orig_blit_endEncoding(blit, @selector(endEncoding));
                    }
                }
            }
        }
        cb_sync_release_entry(&entry);
    }
    orig_cb_commit(self, _cmd);
}

static void hook_cb_dealloc(__unsafe_unretained id self, SEL _cmd) {
    CBSyncEntry entry;
    if (cb_sync_pop((uintptr_t)(__bridge void *)self, &entry)) {
        cb_sync_release_entry(&entry);
    }
    orig_cb_dealloc(self, _cmd);
}

static void hook_blit_syncRes(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id<MTLResource> res) {
    if (res && [res conformsToProtocol:@protocol(MTLTexture)]) {
        uintptr_t cb_key = subenc_get((uintptr_t)(__bridge void *)self);
        if (cb_key) cb_sync_clear_tex(cb_key, (id<MTLTexture>)res);
    }
    orig_blit_syncRes(self, _cmd, res);
}

static void hook_blit_syncTex(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id<MTLTexture> tex, NSUInteger slice, NSUInteger level) {
    if (tex && tex.arrayLength == 1 && tex.mipmapLevelCount == 1 &&
        tex.textureType != MTLTextureTypeCube && tex.textureType != MTLTextureTypeCubeArray) {
        uintptr_t cb_key = subenc_get((uintptr_t)(__bridge void *)self);
        if (cb_key) cb_sync_clear_tex(cb_key, tex);
    }
    orig_blit_syncTex(self, _cmd, tex, slice, level);
}

static void hook_blit_copyTexOrigin(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id<MTLTexture> src, NSUInteger ss, NSUInteger sl, MTLOrigin so, MTLSize sz, __unsafe_unretained id<MTLTexture> dst, NSUInteger ds, NSUInteger dl, MTLOrigin dorig) {
    if (dst) {
        uintptr_t cb_key = subenc_get((uintptr_t)(__bridge void *)self);
        if (cb_key) cb_sync_mark_tex(cb_key, dst);
    }
    orig_blit_copyTexOrigin(self, _cmd, src, ss, sl, so, sz, dst, ds, dl, dorig);
}

static void hook_blit_copyTexSlices(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id<MTLTexture> src, NSUInteger ss, NSUInteger sl, __unsafe_unretained id<MTLTexture> dst, NSUInteger ds, NSUInteger dl, NSUInteger sc, NSUInteger lc) {
    if (dst) {
        uintptr_t cb_key = subenc_get((uintptr_t)(__bridge void *)self);
        if (cb_key) cb_sync_mark_tex(cb_key, dst);
    }
    orig_blit_copyTexSlices(self, _cmd, src, ss, sl, dst, ds, dl, sc, lc);
}

static void hook_blit_copyBufToTex(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id<MTLBuffer> src, NSUInteger off, NSUInteger bpr, NSUInteger bpi, MTLSize sz, __unsafe_unretained id<MTLTexture> dst, NSUInteger ds, NSUInteger dl, MTLOrigin dorig) {
    if (dst) {
        uintptr_t cb_key = subenc_get((uintptr_t)(__bridge void *)self);
        if (cb_key) cb_sync_mark_tex(cb_key, dst);
    }
    orig_blit_copyBufToTex(self, _cmd, src, off, bpr, bpi, sz, dst, ds, dl, dorig);
}

static void hook_blit_copyBufToTexOpts(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id<MTLBuffer> src, NSUInteger off, NSUInteger bpr, NSUInteger bpi, MTLSize sz, __unsafe_unretained id<MTLTexture> dst, NSUInteger ds, NSUInteger dl, MTLOrigin dorig, MTLBlitOption opts) {
    if (dst) {
        uintptr_t cb_key = subenc_get((uintptr_t)(__bridge void *)self);
        if (cb_key) cb_sync_mark_tex(cb_key, dst);
    }
    orig_blit_copyBufToTexOpts(self, _cmd, src, off, bpr, bpi, sz, dst, ds, dl, dorig, opts);
}

static void hook_blit_genMips(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id<MTLTexture> tex) {
    if (tex) {
        uintptr_t cb_key = subenc_get((uintptr_t)(__bridge void *)self);
        if (cb_key) cb_sync_mark_tex(cb_key, tex);
    }
    orig_blit_genMips(self, _cmd, tex);
}

static void hook_blit_endEncoding(__unsafe_unretained id self, SEL _cmd) {
    subenc_del((uintptr_t)(__bridge void *)self);
    orig_blit_endEncoding(self, _cmd);
}

static void hook_blit_dealloc(__unsafe_unretained id self, SEL _cmd) {
    subenc_del((uintptr_t)(__bridge void *)self);
    orig_blit_dealloc(self, _cmd);
}

static void hook_comp_setTex(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id<MTLTexture> tex, NSUInteger idx) {
    if (tex && (tex.usage & MTLTextureUsageShaderWrite)) {
        uintptr_t cb_key = subenc_get((uintptr_t)(__bridge void *)self);
        if (cb_key) cb_sync_mark_tex(cb_key, tex);
    }
    orig_comp_setTex(self, _cmd, tex, idx);
}

static void hook_comp_setTexRange(__unsafe_unretained id self, SEL _cmd, const __unsafe_unretained id<MTLTexture> *texs, NSRange range) {
    if (texs && range.length > 0) {
        uintptr_t cb_key = 0;
        for (NSUInteger i = 0; i < range.length; i++) {
            id<MTLTexture> tex = texs[i];
            if (tex && (tex.usage & MTLTextureUsageShaderWrite)) {
                if (!cb_key) {
                    cb_key = subenc_get((uintptr_t)(__bridge void *)self);
                    if (!cb_key) break;
                }
                cb_sync_mark_tex(cb_key, tex);
            }
        }
    }
    orig_comp_setTexRange(self, _cmd, texs, range);
}

static void hook_comp_endEncoding(__unsafe_unretained id self, SEL _cmd) {
    subenc_del((uintptr_t)(__bridge void *)self);
    orig_comp_endEncoding(self, _cmd);
}

static void hook_comp_dealloc(__unsafe_unretained id self, SEL _cmd) {
    subenc_del((uintptr_t)(__bridge void *)self);
    orig_comp_dealloc(self, _cmd);
}

static void hook_setPSO(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained id<MTLRenderPipelineState> pso) {
    orig_setPSO(self, _cmd, pso);
    if (atomic_load_explicit(&g_pso_count, memory_order_relaxed) == 0) {
        return;
    }
    RBPSOTag tag = {0, 0};
    BOOL isRB = pso ? pso_table_get((uintptr_t)(__bridge void *)pso, &tag) : NO;

    id<MTLTexture> toBind[3] = {nil, nil, nil};
    os_unfair_lock_lock(&g_enc_lock);
    RBEncEntry *e = enc_table_find_locked((uintptr_t)(__bridge void *)self);
    if (e) {
        if (isRB) {
            e->cur_is_rb = 1;
            e->cur_read = tag.read_mask;
            e->cur_write = tag.write_mask;
            for (int i = 0; i < 3; i++) {
                if ((tag.read_mask & (1u << i)) && e->att[i] && !e->bound[i]) {
                    toBind[i] = e->att[i];
                    e->bound[i] = 1;
                }
            }
        } else {
            e->cur_is_rb = 0;
            e->cur_read = 0;
            e->cur_write = 0x7;
        }
    }
    os_unfair_lock_unlock(&g_enc_lock);

    for (int i = 0; i < 3; i++) {
        if (toBind[i] && (toBind[i].usage & MTLTextureUsageShaderRead)) {
            orig_setFragTex(self, @selector(setFragmentTexture:atIndex:), toBind[i], (NSUInteger)(4 + i));
        }
    }
}

static inline void pre_draw_barrier_and_mark(__unsafe_unretained id self) {
    if (atomic_load_explicit(&g_pso_count, memory_order_relaxed) == 0) {
        return;
    }
    BOOL needBarrier = NO;
    os_unfair_lock_lock(&g_enc_lock);
    RBEncEntry *e = enc_table_find_locked((uintptr_t)(__bridge void *)self);
    if (e) {
        if (e->cur_is_rb) {
            if ((e->cur_read & e->dirty) != 0) {
                needBarrier = YES;
                e->dirty = 0;
            }
            e->dirty |= e->cur_write;
        } else {
            e->dirty |= 0x7;
        }
    }
    os_unfair_lock_unlock(&g_enc_lock);

    if (needBarrier && orig_memBarrier) {
        orig_memBarrier(self,
                        @selector(memoryBarrierWithScope:afterStages:beforeStages:),
                        MTLBarrierScopeRenderTargets,
                        MTLRenderStageFragment,
                        MTLRenderStageFragment);
    }
}

static void hook_draw_v(__unsafe_unretained id self, SEL _cmd, MTLPrimitiveType t, NSUInteger vs, NSUInteger vc) {
    pre_draw_barrier_and_mark(self);
    orig_draw_v(self, _cmd, t, vs, vc);
}

static void hook_draw_vi(__unsafe_unretained id self, SEL _cmd, MTLPrimitiveType t, NSUInteger vs, NSUInteger vc, NSUInteger ic) {
    pre_draw_barrier_and_mark(self);
    orig_draw_vi(self, _cmd, t, vs, vc, ic);
}

static void hook_draw_vib(__unsafe_unretained id self, SEL _cmd, MTLPrimitiveType t, NSUInteger vs, NSUInteger vc, NSUInteger ic, NSUInteger bi) {
    pre_draw_barrier_and_mark(self);
    orig_draw_vib(self, _cmd, t, vs, vc, ic, bi);
}

static void hook_draw_ind(__unsafe_unretained id self, SEL _cmd, MTLPrimitiveType t, __unsafe_unretained id<MTLBuffer> buf, NSUInteger off) {
    pre_draw_barrier_and_mark(self);
    orig_draw_ind(self, _cmd, t, buf, off);
}

static void hook_drawIdx(__unsafe_unretained id self, SEL _cmd, MTLPrimitiveType t, NSUInteger ic, MTLIndexType it, __unsafe_unretained id<MTLBuffer> ib, NSUInteger ibo) {
    pre_draw_barrier_and_mark(self);
    orig_drawIdx(self, _cmd, t, ic, it, ib, ibo);
}

static void hook_drawIdx_i(__unsafe_unretained id self, SEL _cmd, MTLPrimitiveType t, NSUInteger ic, MTLIndexType it, __unsafe_unretained id<MTLBuffer> ib, NSUInteger ibo, NSUInteger inst) {
    pre_draw_barrier_and_mark(self);
    orig_drawIdx_i(self, _cmd, t, ic, it, ib, ibo, inst);
}

static void hook_drawIdx_ivb(__unsafe_unretained id self, SEL _cmd, MTLPrimitiveType t, NSUInteger ic, MTLIndexType it, __unsafe_unretained id<MTLBuffer> ib, NSUInteger ibo, NSUInteger inst, NSInteger bv, NSUInteger bi) {
    pre_draw_barrier_and_mark(self);
    orig_drawIdx_ivb(self, _cmd, t, ic, it, ib, ibo, inst, bv, bi);
}

static void hook_drawIdx_ind(__unsafe_unretained id self, SEL _cmd, MTLPrimitiveType t, MTLIndexType it, __unsafe_unretained id<MTLBuffer> ib, NSUInteger ibo, __unsafe_unretained id<MTLBuffer> ind, NSUInteger indOff) {
    pre_draw_barrier_and_mark(self);
    orig_drawIdx_ind(self, _cmd, t, it, ib, ibo, ind, indOff);
}

static void hook_endEncoding(__unsafe_unretained id self, SEL _cmd) {
    if (atomic_load_explicit(&g_rb_lib_loaded, memory_order_relaxed) != 0) {
        enc_table_del((uintptr_t)(__bridge void *)self);
    }
    orig_endEncoding(self, _cmd);
}

static void hook_enc_dealloc(__unsafe_unretained id self, SEL _cmd) {
    if (atomic_load_explicit(&g_rb_lib_loaded, memory_order_relaxed) != 0) {
        enc_table_del((uintptr_t)(__bridge void *)self);
    }
    orig_enc_dealloc(self, _cmd);
}

static BOOL swizzle_method(const char *clsName, SEL sel, IMP newImp, IMP *origOut) {
    Class cls = objc_getClass(clsName);
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP old = method_getImplementation(m);
    if (origOut) *origOut = old;
    if (!class_addMethod(cls, sel, newImp, method_getTypeEncoding(m))) {
        IMP prev = method_setImplementation(m, newImp);
        if (origOut) *origOut = prev;
    }
    return YES;
}

static void install_bronze_hooks(void) {
    if (atomic_load_explicit(&g_bronze_hooked, memory_order_acquire) != 0) {
        return;
    }
    if (!objc_getClass("BronzeMtlDevice") || !objc_getClass("BronzeMtlRenderCmdEncoder")) {
        return;
    }
    uint32_t expected = 0;
    if (!atomic_compare_exchange_strong(&g_bronze_hooked, &expected, 1)) {
        return;
    }

    swizzle_method("BronzeMtlDevice", @selector(newTextureWithDescriptor:),
                   (IMP)hook_dev_newTextureWithDesc, (IMP *)&orig_dev_newTextureWithDesc);
    swizzle_method("BronzeMtlDevice", @selector(newTextureWithDescriptor:iosurface:plane:),
                   (IMP)hook_dev_newTextureWithIOSurface, (IMP *)&orig_dev_newTextureWithIOSurface);
    swizzle_method("BronzeMtlBuffer", @selector(newTextureWithDescriptor:offset:bytesPerRow:),
                   (IMP)hook_buf_newTextureWithDesc, (IMP *)&orig_buf_newTextureWithDesc);
    swizzle_method("BronzeMtlHeap", @selector(newTextureWithDescriptor:),
                   (IMP)hook_heap_newTextureWithDesc, (IMP *)&orig_heap_newTextureWithDesc);
    swizzle_method("BronzeMtlHeap", @selector(newTextureWithDescriptor:atOffset:),
                   (IMP)hook_heap_newTextureWithDescOff, (IMP *)&orig_heap_newTextureWithDescOff);

    swizzle_method("BronzeMtlCmdBuffer", @selector(renderCommandEncoderWithDescriptor:),
                   (IMP)hook_renderCmdEncoder, (IMP *)&orig_renderCmdEncoder);
    swizzle_method("BronzeMtlCmdBuffer", @selector(blitCommandEncoder),
                   (IMP)hook_blitCmdEncoder, (IMP *)&orig_blitCmdEncoder);
    swizzle_method("BronzeMtlCmdBuffer", @selector(computeCommandEncoder),
                   (IMP)hook_compCmdEncoder, (IMP *)&orig_compCmdEncoder);
    swizzle_method("BronzeMtlCmdBuffer", @selector(computeCommandEncoderWithDispatchType:),
                   (IMP)hook_compCmdEncoderDisp, (IMP *)&orig_compCmdEncoderDisp);
    swizzle_method("BronzeMtlCmdBuffer", @selector(commit),
                   (IMP)hook_cb_commit, (IMP *)&orig_cb_commit);
    swizzle_method("BronzeMtlCmdBuffer", sel_registerName("dealloc"),
                   (IMP)hook_cb_dealloc, (IMP *)&orig_cb_dealloc);

    swizzle_method("BronzeMtlBlitCmdEncoder", @selector(synchronizeResource:),
                   (IMP)hook_blit_syncRes, (IMP *)&orig_blit_syncRes);
    swizzle_method("BronzeMtlBlitCmdEncoder", @selector(synchronizeTexture:slice:level:),
                   (IMP)hook_blit_syncTex, (IMP *)&orig_blit_syncTex);
    swizzle_method("BronzeMtlBlitCmdEncoder", @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:),
                   (IMP)hook_blit_copyTexOrigin, (IMP *)&orig_blit_copyTexOrigin);
    swizzle_method("BronzeMtlBlitCmdEncoder", @selector(copyFromTexture:sourceSlice:sourceLevel:toTexture:destinationSlice:destinationLevel:sliceCount:levelCount:),
                   (IMP)hook_blit_copyTexSlices, (IMP *)&orig_blit_copyTexSlices);
    swizzle_method("BronzeMtlBlitCmdEncoder", @selector(copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:),
                   (IMP)hook_blit_copyBufToTex, (IMP *)&orig_blit_copyBufToTex);
    swizzle_method("BronzeMtlBlitCmdEncoder", @selector(copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:options:),
                   (IMP)hook_blit_copyBufToTexOpts, (IMP *)&orig_blit_copyBufToTexOpts);
    swizzle_method("BronzeMtlBlitCmdEncoder", @selector(generateMipmapsForTexture:),
                   (IMP)hook_blit_genMips, (IMP *)&orig_blit_genMips);
    swizzle_method("BronzeMtlBlitCmdEncoder", @selector(endEncoding),
                   (IMP)hook_blit_endEncoding, (IMP *)&orig_blit_endEncoding);
    swizzle_method("BronzeMtlBlitCmdEncoder", sel_registerName("dealloc"),
                   (IMP)hook_blit_dealloc, (IMP *)&orig_blit_dealloc);

    swizzle_method("BronzeMtlComputeCmdEncoder", @selector(setTexture:atIndex:),
                   (IMP)hook_comp_setTex, (IMP *)&orig_comp_setTex);
    swizzle_method("BronzeMtlComputeCmdEncoder", @selector(setTextures:withRange:),
                   (IMP)hook_comp_setTexRange, (IMP *)&orig_comp_setTexRange);
    swizzle_method("BronzeMtlComputeCmdEncoder", @selector(endEncoding),
                   (IMP)hook_comp_endEncoding, (IMP *)&orig_comp_endEncoding);
    swizzle_method("BronzeMtlComputeCmdEncoder", sel_registerName("dealloc"),
                   (IMP)hook_comp_dealloc, (IMP *)&orig_comp_dealloc);

    Class encCls = objc_getClass("BronzeMtlRenderCmdEncoder");
    if (encCls) {
        Method mTex = class_getInstanceMethod(encCls, @selector(setFragmentTexture:atIndex:));
        if (mTex) orig_setFragTex = (void (*)(id, SEL, id<MTLTexture>, NSUInteger))method_getImplementation(mTex);
        Method mBar = class_getInstanceMethod(encCls, @selector(memoryBarrierWithScope:afterStages:beforeStages:));
        if (mBar) orig_memBarrier = (void (*)(id, SEL, MTLBarrierScope, MTLRenderStages, MTLRenderStages))method_getImplementation(mBar);
    }

    swizzle_method("BronzeMtlRenderCmdEncoder", @selector(setRenderPipelineState:),
                   (IMP)hook_setPSO, (IMP *)&orig_setPSO);
    swizzle_method("BronzeMtlRenderCmdEncoder", @selector(drawPrimitives:vertexStart:vertexCount:),
                   (IMP)hook_draw_v, (IMP *)&orig_draw_v);
    swizzle_method("BronzeMtlRenderCmdEncoder", @selector(drawPrimitives:vertexStart:vertexCount:instanceCount:),
                   (IMP)hook_draw_vi, (IMP *)&orig_draw_vi);
    swizzle_method("BronzeMtlRenderCmdEncoder", @selector(drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:),
                   (IMP)hook_draw_vib, (IMP *)&orig_draw_vib);
    swizzle_method("BronzeMtlRenderCmdEncoder", @selector(drawPrimitives:indirectBuffer:indirectBufferOffset:),
                   (IMP)hook_draw_ind, (IMP *)&orig_draw_ind);
    swizzle_method("BronzeMtlRenderCmdEncoder", @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:),
                   (IMP)hook_drawIdx, (IMP *)&orig_drawIdx);
    swizzle_method("BronzeMtlRenderCmdEncoder", @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:),
                   (IMP)hook_drawIdx_i, (IMP *)&orig_drawIdx_i);
    swizzle_method("BronzeMtlRenderCmdEncoder", @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:),
                   (IMP)hook_drawIdx_ivb, (IMP *)&orig_drawIdx_ivb);
    swizzle_method("BronzeMtlRenderCmdEncoder", @selector(drawIndexedPrimitives:indexType:indexBuffer:indexBufferOffset:indirectBuffer:indirectBufferOffset:),
                   (IMP)hook_drawIdx_ind, (IMP *)&orig_drawIdx_ind);
    swizzle_method("BronzeMtlRenderCmdEncoder", @selector(endEncoding),
                   (IMP)hook_endEncoding, (IMP *)&orig_endEncoding);
    swizzle_method("BronzeMtlRenderCmdEncoder", sel_registerName("dealloc"),
                   (IMP)hook_enc_dealloc, (IMP *)&orig_enc_dealloc);
}

#ifdef GG_RB_SELFTEST
__attribute__((visibility("default")))
void gg_rb_test_tag_library(id lib) {
    if (lib) {
        install_bronze_hooks();
        objc_setAssociatedObject(lib, kRBLibKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        atomic_store_explicit(&g_rb_lib_loaded, 1, memory_order_release);
    }
}

__attribute__((visibility("default")))
uint64_t gg_uma_test_auto_sync_ops(void) {
    return atomic_load_explicit(&g_uma_auto_sync_ops, memory_order_relaxed);
}
#endif

__attribute__((constructor))
static void gg_renderbox_fbread_init(void) {
    struct utsname u;
    int darwin_major = (uname(&u) == 0) ? atoi(u.release) : 0;
    if (darwin_major < 27 && !getenv("GG_RB_FIX_FORCE")) {
        return;
    }

    swizzle_method("_MTLDevice", @selector(newLibraryWithURL:error:),
                   (IMP)hook_newLibraryWithURL, (IMP *)&orig_newLibraryWithURL);

    swizzle_method("MTLFunctionConstantValuesInternal", @selector(setConstantValue:type:atIndex:),
                   (IMP)hook_setConstantValue, (IMP *)&orig_setConstantValue);
    swizzle_method("MTLFunctionConstantValuesInternal", @selector(copyWithZone:),
                   (IMP)hook_cv_copyWithZone, (IMP *)&orig_cv_copyWithZone);

    swizzle_method("_MTLLibrary", @selector(newFunctionWithDescriptor:error:),
                   (IMP)hook_newFnWithDesc_err, (IMP *)&orig_newFnWithDesc_err);
    swizzle_method("_MTLLibrary", @selector(newFunctionWithDescriptor:completionHandler:),
                   (IMP)hook_newFnWithDesc_cb, (IMP *)&orig_newFnWithDesc_cb);
    swizzle_method("_MTLLibrary", @selector(newFunctionWithName:constantValues:error:),
                   (IMP)hook_newFnWithName_cv_err, (IMP *)&orig_newFnWithName_cv_err);
    swizzle_method("_MTLLibrary", @selector(newFunctionWithName:constantValues:completionHandler:),
                   (IMP)hook_newFnWithName_cv_cb, (IMP *)&orig_newFnWithName_cv_cb);

    swizzle_method("_MTLDevice", @selector(newRenderPipelineStateWithDescriptor:error:),
                   (IMP)hook_newPSO_err, (IMP *)&orig_newPSO_err);
    swizzle_method("_MTLDevice", @selector(newRenderPipelineStateWithDescriptor:options:reflection:error:),
                   (IMP)hook_newPSO_opt_ref_err, (IMP *)&orig_newPSO_opt_ref_err);
    swizzle_method("_MTLDevice", @selector(newRenderPipelineStateWithDescriptor:completionHandler:),
                   (IMP)hook_newPSO_cb, (IMP *)&orig_newPSO_cb);
    swizzle_method("_MTLDevice", @selector(newRenderPipelineStateWithDescriptor:options:completionHandler:),
                   (IMP)hook_newPSO_opt_cb, (IMP *)&orig_newPSO_opt_cb);

    install_bronze_hooks();
}
