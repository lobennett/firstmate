// Shared optional Calm working visual. Kept inside the mod for Claude's import sandbox;
// Pi reaches this module through its tracked symlink. No timers, host APIs, or input policy.
import type { CalmWorkingShipFrame } from "./fm-calm-working-ship-sprite.ts";

export type CalmWorkingPresentation = "boat" | "resting-state";

/** Missing, unreadable, or future values retain the legacy boat. */
export function parseCalmWorkingPresentation(stored: string | undefined): CalmWorkingPresentation {
  return stored?.trim() === "resting-state" ? "resting-state" : "boat";
}

/** Additive preference beside config/calm; never changes that file's on/off schema. */
export function calmWorkingPresentationPath(calmPath: string): string {
  return `${calmPath}-presentation`;
}

/** Explicit command only: no model invocation or supervision effect. */
export function restingStateChoice(
  args: string,
  active: boolean,
  presentation: CalmWorkingPresentation,
): { active: boolean; presentation: CalmWorkingPresentation } | undefined {
  switch (args.trim()) {
    case "": return { active: !(active && presentation === "resting-state"), presentation: "resting-state" };
    case "on": return { active: true, presentation: "resting-state" };
    case "off": return { active: false, presentation };
    case "boat": return { active: true, presentation: "boat" };
    default: return undefined;
  }
}

// Muted blue-gray, without dim/blink attributes or changing brightness over time.
// The same colors are used by Pi and Claude; custom/unknown appearances use light.
export const RESTING_STATE_PALETTES = { dark: 0x81969a, light: 0x60767b } as const;

/** One two-row drifting curve with gently evolving shape, not measured activity.
 * The existing 220ms Calm tick advances a quarter-cell; a 20-cell swell takes 17.6s.
 * A slower harmonic gently varies the shape; the complete motion repeats after 35.2s.
 * Braille's subcells connect the curve without a floating marker or brightness pulse.
 * Every glyph is one terminal cell; narrow widths clip the field, not its speed.
 */
export function createRestingStateWave() {
  let phase = 0;
  let renderedPhase = 0;
  const dot = [[1, 2, 4, 64], [8, 16, 32, 128]] as const;
  const height = (x: number): number => {
    const amplitude = 2.25 + 0.55 * Math.sin(phase * Math.PI * 2 / 160);
    return Math.max(0, Math.min(7, Math.round(3.5
      + amplitude * Math.sin((x / 2 - phase / 4) * Math.PI * 2 / 20)
      + 0.45 * Math.sin((x / 2 - phase / 8) * Math.PI * 2 / 10))));
  };
  return {
    tick(): void { phase = (phase + 1) % 160; },
    reset(): void { phase = 0; renderedPhase = 0; },
    restoreLastRendered(): void { phase = renderedPhase; },
    frame(width: number, remember = true): CalmWorkingShipFrame {
      const columns = Math.max(0, Math.floor(width));
      if (columns === 0) return [];
      const length = Math.min(columns, 48);
      const left = Math.floor((columns - length) / 2);
      const frame: { text: string; color: "plain" | "water" }[][] = [];
      for (let row = 0; row < 2; row += 1) {
        const runs: { text: string; color: "plain" | "water" }[] = [{ text: " ".repeat(left), color: "plain" }];
        for (let cell = 0; cell < length; cell += 1) {
          let bits = 0;
          for (let half = 0; half < 2; half += 1) {
            const x = cell * 2 + half;
            const a = height(x);
            const b = height(x + 1);
            for (let y = Math.min(a, b); y <= Math.max(a, b); y += 1) {
              if (Math.floor(y / 4) === row) bits |= dot[half]![y % 4]!;
            }
          }
          runs.push({ text: bits === 0 ? " " : String.fromCodePoint(0x2800 + bits), color: "water" });
        }
        runs.push({ text: " ".repeat(columns - length - left), color: "plain" });
        frame.push(runs);
      }
      if (remember) renderedPhase = phase;
      return frame;
    },
  };
}
