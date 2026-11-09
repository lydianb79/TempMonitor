import SwiftUI
import MetalKit
import QuartzCore

/// Full-window animated fire rendered with Metal. `heat` (0…1) controls
/// height, colour and speed of the flames, so the background reacts to load.
struct FlameBackground: NSViewRepresentable {
    var heat: Double

    func makeCoordinator() -> FlameRenderer { FlameRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 30
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.targetHeat = Float(max(0, min(1, heat)))
    }
}

private struct FlameUniforms {
    var time: Float
    var heat: Float
    var resolution: SIMD2<Float>
}

final class FlameRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private let start = CACurrentMediaTime()
    private var heat: Float = 0.3
    private var phase: Float = 0
    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    var targetHeat: Float = 0.3

    override init() {
        device = MTLCreateSystemDefaultDevice()
        super.init()
        guard let device = device else { return }
        queue = device.makeCommandQueue()
        do {
            // Compiled at runtime, so no Metal toolchain is needed at build time.
            let library = try device.makeLibrary(source: FlameRenderer.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "flameVertex")
            desc.fragmentFunction = library.makeFunction(name: "flameFragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("TempMonitor: Metal pipeline failed: \(error)")
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline = pipeline,
              let queue = queue,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - lastTime))
        lastTime = now
        heat += (targetHeat - heat) * min(1, dt * 1.5)       // smooth transitions
        phase += dt * (0.6 + heat * 1.2)                      // hotter = faster flames

        var u = FlameUniforms(time: phase, heat: heat,
                              resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<FlameUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; float2 uv; };
    struct Uniforms { float time; float heat; float2 resolution; };

    vertex VOut flameVertex(uint vid [[vertex_id]]) {
        const float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        VOut o;
        o.position = float4(p[vid], 0.0, 1.0);
        o.uv = p[vid] * 0.5 + 0.5;          // (0,0) bottom-left
        return o;
    }

    float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    float vnoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        float a = hash21(i), b = hash21(i + float2(1, 0));
        float c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    float fbm(float2 p) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 6; i++) { v += a * vnoise(p); p = p * 2.03 + 17.1; a *= 0.5; }
        return v;
    }

    float3 fireRamp(float t, float heat) {
        float3 c0 = float3(0.0);
        float3 c1 = mix(float3(0.10, 0.02, 0.18), float3(0.40, 0.03, 0.00), heat);
        float3 c2 = mix(float3(0.55, 0.12, 0.05), float3(0.90, 0.15, 0.02), heat);
        float3 c3 = float3(1.00, 0.45, 0.05);
        float3 c4 = float3(1.00, 0.85, 0.45);
        float3 col = mix(c0, c1, smoothstep(0.00, 0.25, t));
        col = mix(col, c2, smoothstep(0.25, 0.50, t));
        col = mix(col, c3, smoothstep(0.50, 0.75, t));
        col = mix(col, c4, smoothstep(0.75, 1.00, t));
        return col;
    }

    fragment float4 flameFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float aspect = u.resolution.x / max(u.resolution.y, 1.0);
        float2 uv = in.uv;
        float2 p = float2(uv.x * aspect, uv.y);
        float t = u.time;

        // domain-warped, upward-scrolling noise
        float2 q = float2(fbm(p * 2.0 + float2(0.0, -t * 0.9)),
                          fbm(p * 2.0 + float2(5.2, -t * 1.1)));
        float n = fbm(p * float2(3.0, 2.2) + q * 1.6 + float2(0.0, -t * 1.6));

        float height = 0.22 + 0.48 * u.heat;
        float base = 1.0 - uv.y / height;
        float intensity = clamp(base + (n - 0.5) * 1.3, 0.0, 1.0);
        intensity = pow(intensity, 1.35);

        float3 col = fireRamp(intensity, u.heat);

        // rising embers
        float2 g = float2(p.x * 14.0, p.y * 9.0 - t * 2.2);
        float2 cell = floor(g), f = fract(g) - 0.5;
        float rnd = hash21(cell);
        float ember = 1.0 - smoothstep(0.0, 0.08, length(f - (float2(hash21(cell + 3.1), hash21(cell + 7.7)) - 0.5) * 0.6));
        ember *= step(0.93 - u.heat * 0.05, rnd) * (1.0 - smoothstep(0.1, 0.95, uv.y));
        col += ember * float3(1.0, 0.55, 0.15) * (0.5 + u.heat);

        // vignette + keep the top dark for legibility
        float2 vc = in.uv - 0.5;
        col *= 1.0 - dot(vc, vc) * 0.9;
        col *= 0.85;
        return float4(col, 1.0);
    }
    """
}
