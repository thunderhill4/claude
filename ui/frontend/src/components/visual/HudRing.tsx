/**
 * The arc-reactor: concentric rotating tick-rings the neural constellation
 * orbits. Purely decorative ambient layer — rendered behind NeuralMesh and
 * marked aria-hidden. Uses a 0..100 viewBox and scales to fill its container.
 */
export function HudRing() {
  // 60 evenly-spaced tick marks around the outer ring.
  const ticks = Array.from({ length: 60 }, (_, i) => i);

  return (
    <svg
      className="pointer-events-none absolute inset-0 h-full w-full"
      viewBox="0 0 100 100"
      preserveAspectRatio="xMidYMid meet"
      aria-hidden="true"
    >
      <defs>
        <radialGradient id="hud-core" cx="50%" cy="50%" r="50%">
          <stop offset="0%" stopColor="var(--hud-amber)" stopOpacity="0.9" />
          <stop offset="35%" stopColor="var(--hud-amber)" stopOpacity="0.28" />
          <stop offset="100%" stopColor="var(--hud-amber)" stopOpacity="0" />
        </radialGradient>
        <filter id="hud-core-glow" x="-100%" y="-100%" width="300%" height="300%">
          <feGaussianBlur stdDeviation="1.4" />
        </filter>
      </defs>

      {/* outer dashed ring, slow spin */}
      <circle
        className="hud-spin"
        cx="50" cy="50" r="46"
        fill="none"
        stroke="var(--hud-line-strong)"
        strokeWidth="0.25"
        strokeDasharray="0.6 2.2"
      />

      {/* tick ring */}
      <g className="hud-spin-rev">
        {ticks.map((i) => {
          const major = i % 5 === 0;
          const a = (i / 60) * Math.PI * 2;
          const r1 = 41;
          const r2 = major ? 38 : 39.6;
          return (
            <line
              key={i}
              x1={50 + Math.cos(a) * r1}
              y1={50 + Math.sin(a) * r1}
              x2={50 + Math.cos(a) * r2}
              y2={50 + Math.sin(a) * r2}
              stroke="var(--hud-line-strong)"
              strokeWidth={major ? 0.35 : 0.18}
              opacity={major ? 0.9 : 0.5}
            />
          );
        })}
      </g>

      {/* mid ring with a bright arc segment, spinning forward */}
      <circle
        className="hud-spin"
        cx="50" cy="50" r="32"
        fill="none"
        stroke="var(--hud-cyan)"
        strokeWidth="0.3"
        strokeDasharray="30 170"
        opacity="0.7"
        pathLength="200"
      />
      <circle
        cx="50" cy="50" r="32"
        fill="none"
        stroke="var(--hud-line)"
        strokeWidth="0.15"
      />

      {/* inner ring, reverse spin */}
      <circle
        className="hud-spin-rev"
        cx="50" cy="50" r="20"
        fill="none"
        stroke="var(--hud-violet)"
        strokeWidth="0.3"
        strokeDasharray="12 60"
        opacity="0.6"
        pathLength="100"
      />

      {/* arc-reactor core */}
      <circle cx="50" cy="50" r="12" fill="url(#hud-core)" filter="url(#hud-core-glow)" className="hud-live-dot" />
      <circle cx="50" cy="50" r="2.2" fill="var(--hud-amber)" filter="url(#hud-core-glow)" />
    </svg>
  );
}
