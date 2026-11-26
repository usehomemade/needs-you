/* The hero scene. The island, the beam (screen-edge glow) and the subtitles
   follow the app's code: Island.swift (sizes, springs, bars, dots, shimmer,
   ring, check), Glow.swift (the shader, ported to WebGL as is) and
   Subtitles.swift (wording, colours, timing). Runs only while on screen. */

type Mode = "idle" | "wake" | "listening" | "thinking" | "sending" | "done" | "speaking";
type Who = "user" | "claude";

const W = 1512;
const H = 982;
const NOTCH_X = W / 2;
// Island.base, notch style: w, h, bottom radius. Expanded states get a 12 pt flare, others 6.
const BASE: Record<Mode, [number, number, number]> = {
  idle: [185, 32, 10], wake: [300, 32, 12], listening: [420, 96, 26], thinking: [310, 32, 12],
  sending: [340, 32, 12], speaking: [440, 96, 26], done: [260, 32, 12],
};
const area = (m: Mode) => BASE[m][0] * BASE[m][1];

/** Island.fakeVoice: syllables inside words inside phrases. */
const fakeVoice = (t: number, seed: number) => {
  const phrase = Math.sin(t * 0.0011 + 1.2) > -0.8 ? 1 : 0.08;
  const syl = Math.max(0, Math.sin(t * 0.016 + seed * 3)) ** 2;
  const word = 0.55 + 0.45 * Math.sin(t * 0.0047 + seed);
  return Math.min(1, phrase * (0.18 + 0.82 * syl * word) + Math.random() * 0.06);
};

const hex = (v: number) => [((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255];
const PALETTE: Record<Who, number[][]> = {
  user: [0xf5f5f7, 0x9ecbff, 0xe8f2ff, 0x7fb4ff].map(hex),
  claude: [0xd97757, 0xf0a37f, 0xc25e3c, 0xffc9a8].map(hex),
};

// Glow.swift's fragment shader, line for line.
const FRAG = `
precision highp float;
uniform vec2 size; uniform float time; uniform float level; uniform float opacity; uniform float scale;
uniform vec3 c0; uniform vec3 c1; uniform vec3 c2; uniform vec3 c3;
varying vec2 uv;
vec3 pal(float t) {
  vec3 acc = vec3(0.0); float ws = 0.0;
  for (int i = 0; i < 4; i++) {
    float d = t - float(i) * 0.25; d -= floor(d + 0.5);
    float w = exp(-d * d * 30.0);
    vec3 c = i == 0 ? c0 : i == 1 ? c1 : i == 2 ? c2 : c3;
    acc += c * w; ws += w;
  }
  return acc / ws;
}
void main() {
  float s = scale;
  vec2 p = uv * size;
  float dl = p.x, dr = size.x - p.x, db = p.y, dt = size.y - p.y;
  float k = 28.0 * s;
  float d = max(0.0, -k * log(exp(-dl / k) + exp(-dr / k) + exp(-db / k) + exp(-dt / k)));
  float T = time; float L = level;
  vec2 q = p / s;
  float shimmer = 0.82 + 0.18 * sin(q.x * 0.0041 - q.y * 0.0033 + T * 1.1);
  float halo = exp(-d / ((38.0 + 26.0 * L) * s)) * (0.5 + 0.4 * L) * shimmer;
  float line = exp(-d / (7.0 * s)) * (0.55 + 0.3 * L);
  float bottom = exp(-db / ((110.0 + 90.0 * L) * s)) * (0.28 + 0.32 * L);
  float flow = 0.20 * sin(q.x * 0.0019 + T * 0.55) + 0.16 * sin(q.y * 0.0024 - T * 0.43)
             + 0.12 * sin((q.x - q.y) * 0.0011 + T * 0.31) + T * 0.035;
  vec3 col = pal(fract(flow));
  float a = clamp(halo + line + bottom, 0.0, 1.0) * opacity;
  gl_FragColor = vec4(col * a, a);
}`;
const VERT = "attribute vec2 p; varying vec2 uv; void main(){ uv = p * 0.5 + 0.5; gl_Position = vec4(p, 0.0, 1.0); }";

class Beam {
  private gl: WebGLRenderingContext | null;
  private loc: Record<string, WebGLUniformLocation | null> = {};
  time = 0; level = 0; opacity = 0;
  targetLevel = 0; targetOpacity = 0;
  palette = PALETTE.user.map((c) => [...c]);
  targetPalette = PALETTE.user;
  running = false;
  constructor(private canvas: HTMLCanvasElement) {
    const gl = canvas.getContext("webgl", { premultipliedAlpha: true, alpha: true, antialias: false });
    this.gl = gl;
    if (!gl) return;
    const sh = (type: number, src: string) => {
      const s = gl.createShader(type)!;
      gl.shaderSource(s, src);
      gl.compileShader(s);
      return s;
    };
    const prog = gl.createProgram()!;
    gl.attachShader(prog, sh(gl.VERTEX_SHADER, VERT));
    gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, FRAG));
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) { this.gl = null; return; }
    gl.useProgram(prog);
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const a = gl.getAttribLocation(prog, "p");
    gl.enableVertexAttribArray(a);
    gl.vertexAttribPointer(a, 2, gl.FLOAT, false, 0, 0);
    for (const n of ["size", "time", "level", "opacity", "scale", "c0", "c1", "c2", "c3"]) this.loc[n] = gl.getUniformLocation(prog, n);
    gl.viewport(0, 0, canvas.width, canvas.height);
  }
  start(who: Who) {
    this.targetPalette = PALETTE[who];
    if (!this.running) this.palette = PALETTE[who].map((c) => [...c]);
    this.targetOpacity = 1;
    this.running = true;
  }
  fadeOut() { this.targetOpacity = 0; this.targetLevel = 0; }
  stop() { this.targetOpacity = 0; this.targetLevel = 0; this.opacity = 0; this.level = 0; this.running = false; this.draw(); }
  tick(dt: number, moving: boolean) {
    const ease = (tau: number) => 1 - Math.exp(-dt / tau);
    this.level += (this.targetLevel - this.level) * ease(0.1);
    this.opacity += (this.targetOpacity - this.opacity) * ease(this.targetOpacity > this.opacity ? 0.12 : 0.15);
    for (let i = 0; i < 4; i++) for (let j = 0; j < 3; j++) this.palette[i][j] += (this.targetPalette[i][j] - this.palette[i][j]) * ease(0.15);
    if (moving) this.time += dt;
    if (this.targetOpacity === 0 && this.opacity < 0.002) { this.opacity = 0; this.running = false; }
    this.draw();
  }
  draw() {
    const gl = this.gl;
    if (!gl) return;
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    if (this.opacity <= 0) return;
    gl.uniform2f(this.loc.size, W, H);
    gl.uniform1f(this.loc.time, this.time);
    gl.uniform1f(this.loc.level, this.level);
    gl.uniform1f(this.loc.opacity, this.opacity);
    gl.uniform1f(this.loc.scale, W / 2560);
    this.palette.forEach((c, i) => gl.uniform3f(this.loc["c" + i], c[0], c[1], c[2]));
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }
}

/** A critically-ish damped spring per value, like SwiftUI's interpolatingSpring. */
class Spring {
  v = 0;
  constructor(public x: number) {}
  step(target: number, dt: number, k: number, c: number) {
    const n = Math.max(1, Math.ceil(dt / 0.004));
    const h = dt / n;
    for (let i = 0; i < n; i++) {
      const a = -k * (this.x - target) - c * this.v;
      this.v += a * h;
      this.x += this.v * h;
    }
  }
}

export const startScene = (root: HTMLElement) => {
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const screen = root.querySelector<HTMLElement>(".sc-screen")!;
  const inner = root.querySelector<HTMLElement>(".sc-inner")!;
  const island = root.querySelector<HTMLElement>(".sc-island")!;
  const path = island.querySelector<SVGPathElement>(".sc-isl-shape path")!;
  const svg = island.querySelector<SVGSVGElement>(".sc-isl-shape")!;
  const content = island.querySelector<HTMLElement>(".sc-isl-content")!;
  const layers = [...island.querySelectorAll<HTMLElement>("[data-layer]")];
  const subs = root.querySelector<HTMLElement>("[data-subs]")!;
  const timer = root.querySelector<HTMLElement>("[data-timer]")!;
  const ring = root.querySelector<SVGCircleElement>("[data-ring]")!;
  const shimmer = root.querySelector<HTMLElement>(".sc-shimmer")!;
  const dots = [...root.querySelectorAll<HTMLElement>(".sc-dots i")];
  const barSets = [...root.querySelectorAll<HTMLElement>(".sc-bars")].map((el) => ({
    el, bars: [...el.querySelectorAll<HTMLElement>("i")], warm: el.classList.contains("warm"), wake: el.classList.contains("sc-bars-wake"),
  }));
  const spinner = root.querySelector<HTMLElement>('[data-show="spinner"]')!;
  const beam = new Beam(root.querySelector<HTMLCanvasElement>(".sc-beam")!);

  // Fit the 1512 pt screen to the page. Narrow pages show the part around the
  // notch and the Claude Code window, at a readable size.
  const fit = () => {
    const s = screen.clientWidth / W;
    for (const el of root.querySelectorAll<HTMLElement>(".sc-inner")) el.style.transform = "scale(" + s + ")";
  };
  new ResizeObserver(fit).observe(screen);
  fit();

  // Island state
  let mode: Mode = "idle";
  const sw = new Spring(185), sh = new Spring(32), sr = new Spring(10), sf = new Spring(6);
  let springK = 380, springC = 26;
  let modeAt = 0;
  const history = new Array(26).fill(0);
  let smooth = 0;
  let mic = 0;
  let envelope: number[] = [];
  let speakAt = 0;
  let listenAt = 0;
  let sendAt = 0;

  const setMode = (next: Mode, now: number) => {
    if (next === mode) return;
    const grow = area(next) >= area(mode);
    [springK, springC] = reduce ? [900, 60] : grow ? [380, 26] : [500, 45];
    mode = next;
    modeAt = now;
    island.dataset.mode = next;
    for (const l of layers) l.toggleAttribute("data-on", l.dataset.layer === next);
    if (next === "listening") listenAt = now;
    if (next === "sending") sendAt = now;
  };

  const drawIsland = () => {
    const w = sw.x, h = sh.x, r = Math.max(0, sr.x), f = Math.max(0, sf.x);
    const total = w + 2 * f;
    island.style.width = total + "px";
    island.style.height = h + "px";
    island.style.left = NOTCH_X - total / 2 + "px";
    svg.setAttribute("viewBox", "0 0 " + total + " " + h);
    svg.setAttribute("width", String(total));
    svg.setAttribute("height", String(h));
    const x0 = f, x1 = total - f;
    const br = Math.min(r, w / 2, h / 2);
    path.setAttribute("d",
      "M0 0H" + total +
      "Q" + x1 + " 0 " + x1 + " " + f +
      "V" + (h - br) + "Q" + x1 + " " + h + " " + (x1 - br) + " " + h +
      "H" + (x0 + br) + "Q" + x0 + " " + h + " " + x0 + " " + (h - br) +
      "V" + f + "Q" + x0 + " 0 0 0Z");
    content.style.left = f + "px";
    content.style.width = w + "px";
    content.style.height = h + "px";
  };

  const target = (now: number) => {
    if (mode === "speaking") {
      const k = Math.floor((now - speakAt) / 50);
      return k >= 0 && k < envelope.length ? envelope[k] * 0.95 : 0;
    }
    return mode === "listening" || mode === "wake" ? mic : 0;
  };

  let lastPush = 0;
  const drawBars = (now: number) => {
    const dt = now - lastPush;
    if (dt >= 1000 / 62) {
      const steps = lastPush === 0 ? 1 : Math.min(26, Math.floor((dt / 1000) * 60));
      lastPush = now;
      const t = target(now);
      for (let i = 0; i < Math.max(1, steps); i++) {
        smooth += (t - smooth) * (t > smooth ? 0.6 : 0.25);
        history.shift();
        history.push(smooth);
      }
    }
    for (const set of barSets) {
      const visible = (set.warm && mode === "speaking") || (set.wake && mode === "wake") || (!set.warm && !set.wake && mode === "listening");
      if (!visible) continue;
      const n = set.bars.length;
      const height = set.wake ? 14 : 28;
      const bw = set.wake ? 2.5 : 3;
      set.bars.forEach((bar, i) => {
        let s: number;
        if (set.wake) {
          const v = history[history.length - 1];
          const wobble = 0.6 + 0.4 * Math.sin((now / 1000) * 9 + i * 1.3);
          s = 0.2 + 0.8 * Math.min(1, v * wobble);
        } else {
          const half = (n - 1) / 2;
          const d = Math.abs(i - half) / half;
          const last = history.length - 1;
          const k = Math.round(last - d * last);
          s = Math.max(0.1, history[k] * (1 - d * 0.55));
        }
        bar.style.height = Math.max(bw, height * s) + "px";
      });
    }
  };

  const drawDetails = (now: number) => {
    if (mode === "listening") {
      const sec = Math.max(0, Math.floor((now - listenAt) / 1000));
      timer.textContent = Math.floor(sec / 60) + ":" + String(sec % 60).padStart(2, "0");
    }
    if (mode === "thinking") {
      dots.forEach((dot, i) => {
        const t = now / 1000 - i * 0.15;
        const p = (((t % 1.2) + 1.2) % 1.2) / 1.2;
        const x = p < 0.4 ? p / 0.4 : 1 - (p - 0.4) / 0.6;
        const k = reduce ? 0 : x * x * (3 - 2 * x);
        dot.style.opacity = String(reduce ? 0.7 : 0.3 + 0.7 * k);
        dot.style.transform = "translateY(" + -2 * k + "px)";
      });
      // Shimmer.center: the band's middle sweeps from -0.35 to 1.35 of the text in 1.6 s.
      const p = ((now / 1000) % 1.6) / 1.6;
      const c = reduce ? 0.5 : -0.35 + 1.7 * p;
      shimmer.style.setProperty("--a", (c - 0.35) * 100 + "%");
      shimmer.style.setProperty("--b", (c + 0.35) * 100 + "%");
      shimmer.style.setProperty("--m", c * 100 + "%");
    }
    if (mode === "sending") {
      const left = Math.max(0, 1 - (now - sendAt) / 2000);
      ring.style.strokeDashoffset = String(44 * (1 - left));
    }
  };

  // Subtitles: his words white, Claude's peach; the newest word still settling is dimmer.
  const say = (who: Who, text: string, pending = "") => {
    subs.dataset.who = who;
    subs.innerHTML = "";
    subs.append(text);
    if (pending) {
      const dim = document.createElement("span");
      dim.textContent = (text ? " " : "") + pending;
      subs.append(dim);
    }
    subs.dataset.on = "";
  };
  const hideSubs = () => { delete subs.dataset.on; };
  const words = (sentence: string, from: number, to: number) => {
    const ws = sentence.split(" ");
    return ws.map((_, i) => [from + ((to - from) * i) / ws.length, ws.slice(0, i).join(" "), ws[i]] as const);
  };

  const show = (name: string, on: boolean) => {
    for (const el of root.querySelectorAll<HTMLElement>('[data-step="' + name + '"], [data-show="' + name + '"]')) el.hidden = !on;
  };

  // The story, in ms from the start of the loop.
  const QUESTION = "Tests pass. Ship it to staging?";
  const ANSWER = "Yes, ship it.";
  const COMMAND = "Hey Mac, docs site: add the rounding fix to the 2.4 release notes";
  const events: [number, (now: number) => void][] = [
    [0, (now) => {
      for (const n of ["ask", "answered", "deploy", "deployed", "shipped", "typed"]) show(n, false);
      for (const n of ["waiting", "deploying", "spinner", "placeholder"]) show(n, true);
      root.querySelector('[data-dot="ask"]')?.classList.add("run");
      root.classList.remove("codex-front");
      hideSubs();
      beam.stop();
      setMode("idle", now);
    }],
    [1400, () => show("ask", true)],
    [1900, (now) => {
      envelope = Array.from({ length: 70 }, (_, i) => fakeVoice(i * 50, 0.9) * 0.95);
      speakAt = now;
      setMode("speaking", now);
      beam.start("claude");
      say("claude", QUESTION);
    }],
    [5300, (now) => {
      // Playback ended: the mic opens for his answer.
      setMode("listening", now);
      beam.start("user");
      hideSubs();
    }],
    ...words(ANSWER, 5700, 7000).map(([at, text, pending]) => [at, () => say("user", text, pending)] as [number, (n: number) => void]),
    [7300, (now) => { setMode("thinking", now); mic = 0; }],
    [7600, () => say("user", ANSWER)],
    [7900, () => beam.fadeOut()],
    [8300, (now) => {
      setMode("done", now);
      show("waiting", false);
      show("answered", true);
      root.querySelector('[data-dot="ask"]')?.classList.remove("run");
    }],
    [9400, (now) => setMode("idle", now)],
    [9900, () => { hideSubs(); show("deploy", true); }],
    [11600, () => { show("deploying", false); show("deployed", true); }],
    [12200, () => { show("shipped", true); show("spinner", false); }],
    [13800, (now) => { setMode("wake", now); beam.start("user"); }],
    ...words(COMMAND, 14000, 17400).map(([at, text, pending]) => [at, () => say("user", text, pending)] as [number, (n: number) => void]),
    [14600, (now) => setMode("listening", now)],
    [17800, (now) => { setMode("thinking", now); mic = 0; }],
    [18100, () => say("user", COMMAND)],
    [18400, () => beam.fadeOut()],
    [18900, (now) => setMode("sending", now)],
    [20100, () => hideSubs()],
    [20900, (now) => {
      root.classList.add("codex-front");
      show("typed", true);
      show("placeholder", false);
      setMode("done", now);
    }],
    [22000, (now) => setMode("idle", now)],
  ];
  events.sort((a, b) => a[0] - b[0]);
  const LOOP = 26500;

  let clock = 0;
  let next = 0;
  let last = 0;
  let visible = true;
  let frame = 0;
  const glyphs = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"];
  const spinGlyph = spinner.firstChild as Text;

  const runEvents = (now: number) => {
    while (next < events.length && events[next][0] <= clock) {
      events[next][1](now);
      next++;
    }
    if (clock >= LOOP) { clock = 0; next = 0; }
  };

  const loop = (t: number) => {
    frame = 0;
    const dt = last ? Math.min(100, t - last) : 16;
    last = t;
    clock += dt;
    runEvents(t);
    if (mode === "listening" || mode === "wake") mic = fakeVoice(clock, 0.3);
    beam.targetLevel = mode === "speaking" ? target(t) : mode === "listening" || mode === "wake" ? mic : 0;
    const k = dt / 1000;
    const [w, h, r] = BASE[mode];
    sw.step(w, k, springK, springC);
    sh.step(h, k, springK, springC);
    sr.step(r, k, springK, springC);
    sf.step(h > 40 ? 12 : 6, k, springK, springC);
    drawIsland();
    drawBars(t);
    drawDetails(t);
    if (beam.running) beam.tick(k, true);
    spinGlyph.textContent = glyphs[Math.floor(t / 120) % glyphs.length] + " Thinking… ";
    if (visible && !document.hidden) frame = requestAnimationFrame(loop);
  };
  const resume = () => {
    if (!frame && visible && !document.hidden) { last = 0; frame = requestAnimationFrame(loop); }
  };

  if (reduce) {
    // One still frame: Claude has asked, the question is on screen, the beam is lit.
    for (const [at, fn] of events) if (at <= 3000) fn(0);
    sw.x = BASE.speaking[0]; sh.x = BASE.speaking[1]; sr.x = BASE.speaking[2]; sf.x = 12;
    drawIsland();
    beam.opacity = 1; beam.level = 0.4; beam.time = 4;
    beam.draw();
    for (const set of barSets) set.bars.forEach((b, i) => (b.style.height = 6 + 14 * Math.abs(Math.sin(i * 0.7)) + "px"));
    spinGlyph.textContent = "✻ Thinking… ";
    return;
  }
  new IntersectionObserver(([e]) => { visible = e.isIntersecting; resume(); }).observe(root);
  document.addEventListener("visibilitychange", resume);
  resume();
};
