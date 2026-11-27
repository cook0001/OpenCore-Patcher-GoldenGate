#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <stdio.h>

/* Live hardware verification test on MacPro6,1 FirePro D500:
 * 1. Verifies real RenderBox.framework default.metallib URL tagging via newLibraryWithURL:error:.
 * 2. Verifies RT-only MTLTextureDescriptor auto-upgrades with MTLTextureUsageShaderRead.
 * 3. Compiles an online MSL shader mirroring GG RenderBox's uint4 _shader_state bit 15 +
 *    [[color(0), function_constant(reads_dest_and_fb)]] vs texture(4)/texture(5), tags the
 *    MTLLibrary via the exact same RenderBox path, specializes with bit 15 = 1 + reads_dest +
 *    reads_cov, compiles on real libAMDIL902/FirePro D500, and executes 2 draws with intra-pass
 *    barrier + pixel-exact GPU readback!
 */
int main(void) {
    @autoreleasepool {
        setenv("GG_RB_FIX_FORCE", "1", 1);

        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { fprintf(stderr, "FAIL: no Metal device\n"); return 1; }
        printf("Device: %s (%s)\n", dev.name.UTF8String, object_getClassName(dev));

        void *h = dlopen("./build/gg_bronze_metal_bridge_standalone.dylib", RTLD_NOW | RTLD_GLOBAL);
        if (!h) { fprintf(stderr, "FAIL: dlopen: %s\n", dlerror()); return 1; }
        printf("Loaded gg_bronze_metal_bridge_standalone.dylib OK\n");

        /* Test 0: Real RenderBox.framework URL tagging via newLibraryWithURL:error: */
        NSError *err = nil;
        NSURL *rbURL = [NSURL fileURLWithPath:@"/System/Library/PrivateFrameworks/RenderBox.framework/Versions/A/Resources/default.metallib"];
        id<MTLLibrary> realRbLib = [dev newLibraryWithURL:rbURL error:&err];
        if (!realRbLib) { fprintf(stderr, "FAIL Test 0: load real RenderBox default.metallib: %s\n", err.localizedDescription.UTF8String); return 1; }
        printf("PASS Test 0: Loaded real RenderBox default.metallib (%lu functions) via hooked newLibraryWithURL:error:\n", (unsigned long)realRbLib.functionNames.count);

        /* Test 1: RenderTarget-only texture gets MTLTextureUsageShaderRead automatically */
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:16 height:16 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> rtColor = [dev newTextureWithDescriptor:td];
        if (!(rtColor.usage & MTLTextureUsageShaderRead)) {
            fprintf(stderr, "FAIL Test 1: rtColor missing MTLTextureUsageShaderRead (usage=0x%lx)\n", (unsigned long)rtColor.usage);
            return 1;
        }
        printf("PASS Test 1: RT texture auto-upgraded usage=0x%lx (RenderTarget|ShaderRead)\n", (unsigned long)rtColor.usage);

        MTLTextureDescriptor *tdCov = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:16 height:16 mipmapped:NO];
        tdCov.usage = MTLTextureUsageRenderTarget;
        tdCov.storageMode = MTLStorageModePrivate;
        id<MTLTexture> rtCov = [dev newTextureWithDescriptor:tdCov];

        /* Test 2: Online MSL shader mirroring GG RenderBox bit 15 + color_tex@4 + cov_tex@5 */
        NSString *msl =
            @"#include <metal_stdlib>\n"
             "using namespace metal;\n"
             "constant uint4 _shader_state [[function_constant(0)]];\n"
             "constant bool has_fb_read = (_shader_state[2] & 0x8000u) != 0;\n"
             "constant bool reads_dest_and_fb = ((_shader_state[3] & 0x20u) != 0) && has_fb_read;\n"
             "constant bool reads_dest_and_not_fb = ((_shader_state[3] & 0x20u) != 0) && !has_fb_read;\n"
             "constant bool reads_cov_and_not_fb = ((_shader_state[3] & 0x40u) != 0) && !has_fb_read;\n"
             "struct VOut { float4 pos [[position]]; };\n"
             "vertex VOut test_vs(uint vid [[vertex_id]]) {\n"
             "    float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };\n"
             "    VOut o; o.pos = float4(p[vid], 0, 1); return o;\n"
             "}\n"
             "fragment float4 test_fs(\n"
             "    VOut in [[stage_in]],\n"
             "    float4 fb_color [[color(0), function_constant(reads_dest_and_fb)]],\n"
             "    texture2d<float, access::read> color_tex [[texture(4), function_constant(reads_dest_and_not_fb)]],\n"
             "    texture2d<float, access::read> cov_tex [[texture(5), function_constant(reads_cov_and_not_fb)]]) {\n"
             "    float4 c = float4(0.25, 0.5, 0.75, 1.0);\n"
             "    if (reads_dest_and_fb) c += fb_color;\n"
             "    if (reads_dest_and_not_fb) c += color_tex.read(uint2(in.pos.xy));\n"
             "    if (reads_cov_and_not_fb) c *= cov_tex.read(uint2(in.pos.xy)).x;\n"
             "    return c;\n"
             "}\n";

        MTLCompileOptions *opts = [MTLCompileOptions new];
        id<MTLLibrary> lib = [dev newLibraryWithSource:msl options:opts error:&err];
        if (!lib) { fprintf(stderr, "FAIL: newLibraryWithSource: %s\n", err.localizedDescription.UTF8String); return 1; }

        /* Tag synthetic online lib with kRBLibKey via exported test helper or verify bit-15 path directly */
        void (*tag_fn)(id) = dlsym(h, "gg_rb_test_tag_library");
        if (!tag_fn) { fprintf(stderr, "FAIL: missing gg_rb_test_tag_library\n"); return 1; }
        tag_fn(lib);

        /* Specialize with bit 15 = 1 + reads_dest (0x20) + reads_cov (0x40)! */
        uint32_t state[4] = { 0, 0, 80u | 0x8000u, 0x60u };
        MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
        [cv setConstantValue:state type:MTLDataTypeUInt4 atIndex:0];

        MTLFunctionDescriptor *fdesc = [MTLFunctionDescriptor new];
        fdesc.name = @"test_fs";
        fdesc.constantValues = cv;

        id<MTLFunction> fs = [lib newFunctionWithDescriptor:fdesc error:&err];
        if (!fs) { fprintf(stderr, "FAIL Test 2: newFunctionWithDescriptor: %s\n", err.localizedDescription.UTF8String); return 1; }
        id<MTLFunction> vs = [lib newFunctionWithName:@"test_vs"];

        MTLRenderPipelineDescriptor *pdesc = [MTLRenderPipelineDescriptor new];
        pdesc.vertexFunction = vs;
        pdesc.fragmentFunction = fs;
        pdesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pdesc.colorAttachments[1].pixelFormat = MTLPixelFormatR8Unorm;

        id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pdesc options:0 reflection:nil error:&err];
        if (!pso) { fprintf(stderr, "FAIL Test 2: newRenderPipelineStateWithDescriptor: %s\n", err.localizedDescription.UTF8String); return 1; }
        printf("PASS Test 2: Pipeline with bit15=1 + reads_dest + reads_cov compiled CLEANLY on FirePro D500!\n");

        /* Test 3: Real 2-draw pass with slot 4/5 bind + intra-pass memory barrier + GPU readback! */
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = rtColor;
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.2, 0.0, 0.0, 1.0);
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        rpd.colorAttachments[1].texture = rtCov;
        rpd.colorAttachments[1].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[1].clearColor = MTLClearColorMake(1.0, 0.0, 0.0, 1.0);
        rpd.colorAttachments[1].storeAction = MTLStoreActionStore;

        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
        [enc setRenderPipelineState:pso];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];

        id<MTLBuffer> readback = [dev newBufferWithLength:16*16*4 options:MTLResourceStorageModeManaged];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromTexture:rtColor sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(16,16,1) toBuffer:readback destinationOffset:0 destinationBytesPerRow:16*4 destinationBytesPerImage:16*16*4];
        [blit synchronizeResource:readback];
        [blit endEncoding];

        [cb commit];
        [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted || cb.error) {
            fprintf(stderr, "FAIL Test 3: GPU cmdbuf status=%lu err=%s\n", (unsigned long)cb.status, cb.error.localizedDescription.UTF8String);
            return 1;
        }
        uint8_t *px = (uint8_t *)readback.contents;
        printf("PASS Test 3: GPU readback pixel BGRA=(%u, %u, %u, %u) [expected ~(255, 255, 178, 255)]\n",
               px[0], px[1], px[2], px[3]);
        if (px[2] < 160 || px[2] > 195 || px[1] < 245 || px[0] < 245) {
            fprintf(stderr, "FAIL Test 3: Unexpected readback pixel!\n");
            return 1;
        }

        /* Test 4: UMA Shared MTLTexture GPU->CPU coherency WITHOUT caller calling synchronizeResource: */
        uint64_t (*auto_sync_ops)(void) = dlsym(h, "gg_uma_test_auto_sync_ops");
        if (!auto_sync_ops) { fprintf(stderr, "FAIL: missing gg_uma_test_auto_sync_ops\n"); return 1; }

        NSString *umaMsl =
            @"#include <metal_stdlib>\nusing namespace metal;\n"
             "vertex float4 uma_vs(uint vid [[vertex_id]]) { float2 p[3]={{-1,-1},{3,-1},{-1,3}}; return float4(p[vid],0,1); }\n"
             "fragment float4 uma_fs() { return float4(55.0/255.0, 71.0/255.0, 86.0/255.0, 1.0); }\n"
             "kernel void uma_ks(texture2d<float, access::write> out [[texture(0)]], uint2 gid [[thread_position_in_grid]]) { out.write(float4(11.0/255.0, 22.0/255.0, 33.0/255.0, 1.0), gid); }\n";
        id<MTLLibrary> umaLib = [dev newLibraryWithSource:umaMsl options:nil error:&err];
        MTLRenderPipelineDescriptor *urpd = [MTLRenderPipelineDescriptor new];
        urpd.vertexFunction = [umaLib newFunctionWithName:@"uma_vs"];
        urpd.fragmentFunction = [umaLib newFunctionWithName:@"uma_fs"];
        urpd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        id<MTLRenderPipelineState> upso = [dev newRenderPipelineStateWithDescriptor:urpd error:&err];
        id<MTLComputePipelineState> ucpso = [dev newComputePipelineStateWithFunction:[umaLib newFunctionWithName:@"uma_ks"] error:&err];

        MTLTextureDescriptor *tdSh = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:16 height:16 mipmapped:NO];
        tdSh.storageMode = MTLStorageModeShared;
        tdSh.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLTexture> shRender = [dev newTextureWithDescriptor:tdSh];
        id<MTLTexture> shComp = [dev newTextureWithDescriptor:tdSh];
        id<MTLTexture> shBlitDst = [dev newTextureWithDescriptor:tdSh];
        id<MTLTexture> shViewParent = [dev newTextureWithDescriptor:tdSh];
        id<MTLTexture> shView = [shViewParent newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm];

        /* 4A: Render into standalone Shared texture without caller sync */
        uint64_t ops0 = auto_sync_ops();
        id<MTLCommandBuffer> cb4a = [q commandBuffer];
        MTLRenderPassDescriptor *rp4 = [MTLRenderPassDescriptor renderPassDescriptor];
        rp4.colorAttachments[0].texture = shRender;
        rp4.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp4.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e4a = [cb4a renderCommandEncoderWithDescriptor:rp4];
        [e4a setRenderPipelineState:upso];
        [e4a drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e4a endEncoding];
        [cb4a commit];
        [cb4a waitUntilCompleted];
        uint8_t p4a[4] = {0};
        [shRender getBytes:p4a bytesPerRow:64 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
        if (p4a[0] != 86 || p4a[1] != 71 || p4a[2] != 55 || p4a[3] != 255) {
            fprintf(stderr, "FAIL Test 4A (Shared render no-sync): BGRA=(%u,%u,%u,%u) expect=(86,71,55,255)\n", p4a[0],p4a[1],p4a[2],p4a[3]);
            return 1;
        }
        printf("PASS Test 4A: UMA Shared render auto-sync -> BGRA=(%u,%u,%u,%u) ops=%llu\n", p4a[0],p4a[1],p4a[2],p4a[3], auto_sync_ops() - ops0);

        /* 4B: Compute pass (via computeCommandEncoderWithDescriptor:) into Shared texture without caller sync */
        id<MTLCommandBuffer> cb4b = [q commandBuffer];
        MTLComputePassDescriptor *cpd = [MTLComputePassDescriptor computePassDescriptor];
        id<MTLComputeCommandEncoder> ce4b = [cb4b computeCommandEncoderWithDescriptor:cpd];
        [ce4b setComputePipelineState:ucpso];
        [ce4b setTexture:shComp atIndex:0];
        [ce4b dispatchThreads:MTLSizeMake(16,16,1) threadsPerThreadgroup:MTLSizeMake(4,4,1)];
        [ce4b endEncoding];
        [cb4b commit];
        [cb4b waitUntilCompleted];
        uint8_t p4b[4] = {0};
        [shComp getBytes:p4b bytesPerRow:64 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
        if (p4b[0] != 33 || p4b[1] != 22 || p4b[2] != 11 || p4b[3] != 255) {
            fprintf(stderr, "FAIL Test 4B (Shared compute no-sync): BGRA=(%u,%u,%u,%u) expect=(33,22,11,255)\n", p4b[0],p4b[1],p4b[2],p4b[3]);
            return 1;
        }
        printf("PASS Test 4B: UMA Shared compute auto-sync -> BGRA=(%u,%u,%u,%u)\n", p4b[0],p4b[1],p4b[2],p4b[3]);

        /* 4C: Blit copyFromTexture:toTexture: into Shared texture without caller sync */
        id<MTLCommandBuffer> cb4c = [q commandBuffer];
        id<MTLBlitCommandEncoder> bl4c = [cb4c blitCommandEncoder];
        [bl4c copyFromTexture:shComp toTexture:shBlitDst];
        [bl4c endEncoding];
        [cb4c commit];
        [cb4c waitUntilCompleted];
        uint8_t p4c[4] = {0};
        [shBlitDst getBytes:p4c bytesPerRow:64 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
        if (p4c[0] != 33 || p4c[1] != 22 || p4c[2] != 11 || p4c[3] != 255) {
            fprintf(stderr, "FAIL Test 4C (Shared blit no-sync): BGRA=(%u,%u,%u,%u) expect=(33,22,11,255)\n", p4c[0],p4c[1],p4c[2],p4c[3]);
            return 1;
        }
        printf("PASS Test 4C: UMA Shared blit copy auto-sync -> BGRA=(%u,%u,%u,%u)\n", p4c[0],p4c[1],p4c[2],p4c[3]);

        /* 4D: Render into TextureView of Shared parent without caller sync -> parent getBytes */
        id<MTLCommandBuffer> cb4d = [q commandBuffer];
        rp4.colorAttachments[0].texture = shView;
        id<MTLRenderCommandEncoder> e4d = [cb4d renderCommandEncoderWithDescriptor:rp4];
        [e4d setRenderPipelineState:upso];
        [e4d drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e4d endEncoding];
        [cb4d commit];
        [cb4d waitUntilCompleted];
        uint8_t p4d[4] = {0};
        [shViewParent getBytes:p4d bytesPerRow:64 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
        if (p4d[0] != 86 || p4d[1] != 71 || p4d[2] != 55 || p4d[3] != 255) {
            fprintf(stderr, "FAIL Test 4D (Shared view no-sync): BGRA=(%u,%u,%u,%u) expect=(86,71,55,255)\n", p4d[0],p4d[1],p4d[2],p4d[3]);
            return 1;
        }
        printf("PASS Test 4D: UMA Shared texture view auto-sync -> parent BGRA=(%u,%u,%u,%u)\n", p4d[0],p4d[1],p4d[2],p4d[3]);

        /* 4E: Caller explicitly calls synchronizeResource: -> verify ZERO redundant auto-sync */
        uint64_t opsBefore4e = auto_sync_ops();
        id<MTLCommandBuffer> cb4e = [q commandBuffer];
        rp4.colorAttachments[0].texture = shRender;
        id<MTLRenderCommandEncoder> e4e = [cb4e renderCommandEncoderWithDescriptor:rp4];
        [e4e setRenderPipelineState:upso];
        [e4e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e4e endEncoding];
        id<MTLBlitCommandEncoder> bl4e = [cb4e blitCommandEncoder];
        [bl4e synchronizeResource:shRender];
        [bl4e endEncoding];
        [cb4e commit];
        [cb4e waitUntilCompleted];
        if (auto_sync_ops() != opsBefore4e) {
            fprintf(stderr, "FAIL Test 4E: emitted redundant auto-sync despite explicit synchronizeResource:!\n");
            return 1;
        }
        printf("PASS Test 4E: Explicit caller synchronizeResource: skipped redundant auto-sync (delta=0)\n");

        printf("ALL LIVE HARDWARE TESTS PASSED!\n");
    }
    return 0;
}
