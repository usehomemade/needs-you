import AppKit
import Metal
import QuartzCore

/// Soft colour glow along the screen edges, drawn by a Metal fragment shader: a smooth
/// distance-to-edge falloff (no rim, no mask edge), brightest along the bottom, whose
/// colour flows along the edges from low-frequency waves over the screen position (a
/// field, so there is no seam where a gradient would wrap). One colour family per
/// speaker: cool white-blue for him, Claude's orange for Needs You.
///
/// It renders from the view's display link at the display's refresh rate, at half
/// resolution (the glow has no sharp detail), and only while visible: the link is
/// paused when hidden. Level, fade and palette changes are smoothed per frame, so
/// brightness never jumps. With Reduce Motion the colours stand still; it only fades.
final class GlowView: NSView {
    private struct Uniforms {
        var size: SIMD2<Float> = .zero
        var time: Float = 0
        var level: Float = 0
        var opacity: Float = 0
        var scale: Float = 1
        var pad0: Float = 0, pad1: Float = 0
        var c0 = SIMD4<Float>(), c1 = SIMD4<Float>(), c2 = SIMD4<Float>(), c3 = SIMD4<Float>()
    }

    private static func hex(_ v: Int) -> SIMD4<Float> {
        SIMD4(Float(v >> 16 & 255) / 255, Float(v >> 8 & 255) / 255, Float(v & 255) / 255, 1)
    }
    static let userPalette = [0xf5f5f7, 0x9ecbff, 0xe8f2ff, 0x7fb4ff].map(hex)
    static let claudePalette = [0xd97757, 0xf0a37f, 0xc25e3c, 0xffc9a8].map(hex)

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float2 size; float time; float level; float opacity; float scale; float pad0; float pad1; float4 c[4]; };
    struct V { float4 pos [[position]]; float2 uv; };

    vertex V glowVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        V o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); o.uv = p; return o;
    }

    // Cyclic palette: Gaussian weights around four stops on a circle, so it blends
    // smoothly and wraps without a seam.
    static float3 palette(float t, constant U& u) {
        float3 acc = 0.0; float ws = 0.0;
        for (int i = 0; i < 4; i++) {
            float d = t - float(i) * 0.25; d -= rint(d);
            float w = exp(-d * d * 30.0);
            acc += u.c[i].rgb * w; ws += w;
        }
        return acc / ws;
    }

    fragment float4 glowFragment(V in [[stage_in]], constant U& u [[buffer(0)]]) {
        float s = u.scale;
        float2 p = in.uv * u.size;               // points, origin bottom left
        float dl = p.x, dr = u.size.x - p.x, db = p.y, dt = u.size.y - p.y;
        // Smooth minimum of the four edge distances: round, soft corners.
        float k = 28.0 * s;
        float d = max(0.0, -k * log(exp(-dl / k) + exp(-dr / k) + exp(-db / k) + exp(-dt / k)));
        float T = u.time;
        float L = u.level;
        float2 q = p / s;
        // Brightness breathes slowly along the edge.
        float shimmer = 0.82 + 0.18 * sin(q.x * 0.0041 - q.y * 0.0033 + T * 1.1);
        float halo = exp(-d / ((38.0 + 26.0 * L) * s)) * (0.5 + 0.4 * L) * shimmer;
        float line = exp(-d / (7.0 * s)) * (0.55 + 0.3 * L);
        float bottom = exp(-db / ((110.0 + 90.0 * L) * s)) * (0.28 + 0.32 * L);
        float flow = 0.20 * sin(q.x * 0.0019 + T * 0.55)
                   + 0.16 * sin(q.y * 0.0024 - T * 0.43)
                   + 0.12 * sin((q.x - q.y) * 0.0011 + T * 0.31)
                   + T * 0.035;
        float3 col = palette(fract(flow), u);
        float a = clamp(halo + line + bottom, 0.0, 1.0) * u.opacity;
        return float4(col * a, a);
    }
    """

    private static let device = MTLCreateSystemDefaultDevice()
    private static let pipeline: MTLRenderPipelineState? = {
        guard let device else { return nil }
        do {
            let lib = try device.makeLibrary(source: source, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "glowVertex")
            d.fragmentFunction = lib.makeFunction(name: "glowFragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: d)
        } catch {
            Isolation.note("glow shader: \(error.localizedDescription)")
            return nil
        }
    }()
    private static let queue = device?.makeCommandQueue()

    private let metal = CAMetalLayer()
    private var link: CADisplayLink?
    private var u = Uniforms()
    private var palette = GlowView.userPalette
    private var targetPalette = GlowView.userPalette
    private var targetLevel: Float = 0
    private var targetOpacity: Float = 0
    private var lastTick: CFTimeInterval = 0
    private var running = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        metal.device = Self.device
        metal.pixelFormat = .bgra8Unorm
        metal.isOpaque = false
        metal.framebufferOnly = true
        metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metal.contentsGravity = .resize
        metal.magnificationFilter = .linear
        metal.maximumDrawableCount = 3
        return metal
    }

    func layout(for s: CGSize, cornerRadius: CGFloat) {
        u.size = SIMD2(Float(s.width), Float(s.height))
        u.scale = Float(s.width / 2560) // sizes in the shader are for a 27" screen
        // Half the point size: the glow has no sharp detail, so this costs nothing in looks.
        metal.drawableSize = CGSize(width: max(1, s.width / 2), height: max(1, s.height / 2))
    }

    func start(_ who: Subtitles.Speaker) {
        targetPalette = who == .user ? Self.userPalette : Self.claudePalette
        if !running { palette = targetPalette } // fresh start: no colour slide
        targetOpacity = 1
        running = true
        if link == nil {
            link = displayLink(target: self, selector: #selector(tick(_:)))
            link?.add(to: .main, forMode: .common)
        }
        lastTick = 0
        link?.isPaused = false
    }

    /// Level 0...1; the shader gets it smoothed (about 100 ms).
    func setLevel(_ v: CGFloat) { targetLevel = Float(v) }

    func fadeOut() { targetOpacity = 0; targetLevel = 0 }

    /// Hidden: a last clear frame, then no rendering at all.
    func stop() {
        targetOpacity = 0; targetLevel = 0
        u.opacity = 0; u.level = 0
        if running { render() }
        running = false
        link?.isPaused = true
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = l.targetTimestamp
        let dt = Float(lastTick == 0 ? l.duration : min(0.1, now - lastTick))
        lastTick = now
        func ease(_ tau: Float) -> Float { 1 - exp(-dt / tau) }
        u.level += (targetLevel - u.level) * ease(0.1)
        u.opacity += (targetOpacity - u.opacity) * ease(targetOpacity > u.opacity ? 0.12 : 0.15)
        for i in 0..<4 { palette[i] += (targetPalette[i] - palette[i]) * ease(0.15) }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { u.time += dt }
        render()
        // Faded out: stop drawing until the next start.
        if targetOpacity == 0, u.opacity < 0.002 { u.opacity = 0; render(); running = false; l.isPaused = true }
    }

    private func render() {
        guard let pipeline = Self.pipeline, let queue = Self.queue, u.size.x > 0,
              let drawable = metal.nextDrawable(), let cb = queue.makeCommandBuffer() else { return }
        u.c0 = palette[0]; u.c1 = palette[1]; u.c2 = palette[2]; u.c3 = palette[3]
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        var uniforms = u
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}
