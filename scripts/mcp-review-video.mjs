import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

// Call inside the computer-use REPL with an already-inspected browser target.
export async function captureScene(target, directory, name, seconds = 12) {
  if (!/^[a-z0-9-]+$/.test(name) || !Number.isFinite(seconds) || seconds <= 0) {
    throw new Error("Use a simple scene name and a positive display duration");
  }
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const bytes = await target.getScreenshot({ emit: false });
  if (!bytes?.length) throw new Error("No screenshot bytes returned");
  await writeFile(join(directory, `${name}.png`), bytes, { flag: "wx", mode: 0o600 });
  return { name, seconds, capturedAt: new Date().toISOString() };
}

export async function finishVideoManifest(directory, scenes) {
  if (!scenes.length) throw new Error("Capture at least one scene");
  const lines = ["ffconcat version 1.0"];
  for (const { name, seconds } of scenes) {
    if (!/^[a-z0-9-]+$/.test(name) || !Number.isFinite(seconds) || seconds <= 0) {
      throw new Error("Invalid scene");
    }
    lines.push(`file '${name}.png'`, `duration ${seconds}`);
  }
  lines.push(`file '${scenes.at(-1).name}.png'`);
  await writeFile(join(directory, "scenes.ffconcat"), lines.join("\n") + "\n");
  await writeFile(join(directory, "scenes.json"), JSON.stringify({
    kind: "Screenshot walkthrough of actual live-run results; not continuous execution footage",
    scenes,
  }, null, 2) + "\n");
}
