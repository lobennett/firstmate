// Engine-executed hooks: the alternate visual uses the same Calm owner and policy.
import { describe, expect, test } from "claude-code/testing";
import { assistantMessage, calmCommand, decodeCells, isHidden, isStock, PREFERENCE, rasterOf, spinner, toolUse, world } from "./support.ts";

const command = (args = "") => ({ ...calmCommand(), command: "resting-state", args });
const glyphs = (tree: unknown) => {
  const raster = rasterOf(tree)!;
  return decodeCells(raster.cells, raster.columns, raster.rows).glyphs;
};

describe("Resting State", () => {
  test("explicitly selects one wave, retains Calm policy, toggles off, and switches back to the boat", async ($, on) => {
    const { files, clock, journal } = world(on);
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    expect(isStock(await $.ui.render(spinner()))).toBe(true);
    await $.command.run(command());
    expect(files.get(PREFERENCE)).toBe("on\n");
    expect(files.get(`${PREFERENCE}-presentation`)).toBe("resting-state\n");
    const first = await $.ui.render(spinner());
    expect(rasterOf(first)!.rows).toBe(2);
    expect(glyphs(first).join("")).toMatch(/^[ ○\u2800-\u28ff]+$/);
    expect(glyphs(first).join("")).not.toContain("○");
    expect(isHidden(await $.ui.render(toolUse()))).toBe(true);
    expect(isStock(await $.ui.render(assistantMessage("A substantive final result; choose the next experiment.")))).toBe(true);
    await clock.advance(220 * 16);
    expect(journal.blits.length).toBeGreaterThan(0);
    expect(decodeCells(journal.blits.at(-1)!.cells, 38, 2).glyphs).not.toEqual(glyphs(first));
    await $.command.run(command());
    expect(files.get(PREFERENCE)).toBe("off\n");
    const count = journal.blits.length;
    await clock.advance(220 * 20);
    expect(journal.blits.length).toBe(count);
    expect(isStock(await $.ui.render(spinner()))).toBe(true);
    await $.command.run(calmCommand());
    expect(glyphs(await $.ui.render(spinner())).join("")).toMatch(/[\u2800-\u28ff]/);
    await $.command.run(command("boat"));
    expect(files.get(`${PREFERENCE}-presentation`)).toBe("boat\n");
    expect(glyphs(await $.ui.render(spinner()))[1]).toContain("╲▁▁▁╱");
  });

  test("restores the additive preference before drawing and freezes hidden wave motion without a jump", async ($, on) => {
    const { clock, journal, denyBlits } = world(on, { preference: "max\n", presentation: "resting-state\n" });
    const before = glyphs(await $.ui.render(spinner()));
    denyBlits("settled or aborted");
    await clock.advance(220);
    const count = journal.blits.length;
    await clock.advance(220 * 100);
    expect(journal.blits.length).toBe(count);
    denyBlits(undefined);
    expect(glyphs(await $.ui.render(spinner()))).toEqual(before);
    expect(rasterOf(await $.ui.render(spinner("tiny", { columns: 3, rows: 20 })))!.columns).toBe(1);
    expect(rasterOf(await $.ui.render(spinner("narrow", { columns: 12, rows: 20 })))!.rows).toBe(2);
  });

  for (const [theme, color] of [["dark", 0x81969a], ["light", 0x60767b]] as const) {
    test(`uses a static muted wave on ${theme} with Claude's existing reduced-motion preference`, async ($, on) => {
      const { clock, journal } = world(on, { preference: "on\n", presentation: "resting-state\n", reducedMotion: true, theme });
      const raster = rasterOf(await $.ui.render(spinner()))!;
      const cells = decodeCells(raster.cells, 38, 2);
      expect(cells.foregrounds.flat().filter((fg) => fg === color).length).toBeGreaterThan(60);
      expect(cells.glyphs.join("")).not.toContain("○");
      await clock.advance(220 * 40);
      expect(journal.blits).toHaveLength(0);
    });
  }

  test("follows a live reduced-motion change: stops wave motion while on and resumes from the shown frame when off", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n", presentation: "resting-state\n" });
    const reduce = (value: boolean) => $.config.set({
      key: "prefersReducedMotion",
      value,
      previous: !value,
      provider: { plugin: "engine", tier: "core" as const },
      origin: { kind: "composer" as const },
    });
    await $.ui.render(spinner());
    await clock.advance(220 * 4);
    expect(journal.blits.length).toBeGreaterThan(0);
    const shown = decodeCells(journal.blits.at(-1)!.cells, 38, 2).glyphs;
    await reduce(true);
    const frozen = journal.blits.length;
    await clock.advance(220 * 40);
    expect(journal.blits.length).toBe(frozen);
    expect(glyphs(await $.ui.render(spinner()))).toEqual(shown);
    await clock.advance(220 * 40);
    expect(journal.blits.length).toBe(frozen);
    await reduce(false);
    expect(glyphs(await $.ui.render(spinner()))).toEqual(shown);
    await clock.advance(220 * 4);
    expect(journal.blits.length).toBeGreaterThan(frozen);
  });

  test("does not change live choice on failed persistence or invalid input",async ($, on) => {
    const { failWrites, files } = world(on, { preference: "on\n" });
    expect(glyphs(await $.ui.render(spinner()))[1]).toContain("╲▁▁▁╱");
    failWrites("read-only");
    await $.command.run(command("on"));
    expect(glyphs(await $.ui.render(spinner()))[1]).toContain("╲▁▁▁╱");
    expect(files.get(PREFERENCE)).toBe("on\n");
    failWrites(undefined);
    await $.command.run(command("invalid"));
    expect(files.has(`${PREFERENCE}-presentation`)).toBe(false);
  });

  test("keeps both commands and all drawing completely inert without the exact function-hooks opt-in", async ($, on) => {
    const { clock, journal } = world(on, { preference: "on\n", presentation: "resting-state\n", functionHooks: "true" });
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
    expect(isStock(await $.ui.render(spinner()))).toBe(true);
    await clock.advance(220 * 20);
    expect(journal.commands).toHaveLength(0);
    expect(journal.fsReads).toHaveLength(0);
    expect(journal.blits).toHaveLength(0);
  });
});
