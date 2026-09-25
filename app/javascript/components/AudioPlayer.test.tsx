// @vitest-environment happy-dom
import { cleanup, fireEvent, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import { AudioPlayer } from "$app/components/AudioPlayer";

vi.mock("$app/components/UserAgent", () => ({ useUserAgentInfo: () => ({ locale: "en-US" }) }));
afterEach(cleanup);

it.each([
  [3690, 0],
  [1209, 1209],
])("loads saved position %s as %s after learning duration", (saved, expected) => {
  const { container } = render(<AudioPlayer src="https://example.com/audio.mp3" startTime={saved} />);
  const audio = container.querySelector("audio");
  if (!audio) throw new Error("Audio element missing");
  Object.defineProperty(audio, "duration", { value: 3711 });
  audio.play = vi.fn().mockResolvedValue(undefined);
  fireEvent.loadedMetadata(audio);
  expect(audio.currentTime).toBe(expected);
});

it("keeps a mid-file resume when backend duration is longer than the loaded file", () => {
  const { container } = render(<AudioPlayer src="https://example.com/audio.mp3" startTime={45} contentLength={1000} />);
  const audio = container.querySelector("audio");
  if (!audio) throw new Error("Audio element missing");
  Object.defineProperty(audio, "duration", { value: 46 });
  audio.play = vi.fn().mockResolvedValue(undefined);
  fireEvent.loadedMetadata(audio);
  expect(audio.currentTime).toBe(45);
});

it("reports an unplayable file instead of spinning forever", () => {
  const { container } = render(<AudioPlayer src="https://example.com/unplayable.m4a" />);
  const audio = container.querySelector("audio");
  if (!audio) throw new Error("Audio element missing");
  expect(container.querySelector('[role="progressbar"]')).not.toBeNull();

  fireEvent.error(audio);

  expect(container.querySelector('[role="progressbar"]')).toBeNull();
  expect(container.textContent).toContain("This file can't be played in your browser");
});

it("clears the error when the player is given a new file", () => {
  const { container, rerender } = render(<AudioPlayer src="https://example.com/unplayable.m4a" />);
  const audio = container.querySelector("audio");
  if (!audio) throw new Error("Audio element missing");
  fireEvent.error(audio);
  expect(container.textContent).toContain("This file can't be played in your browser");

  rerender(<AudioPlayer src="https://example.com/playable.mp3" />);

  expect(container.textContent).not.toContain("This file can't be played in your browser");
  expect(container.querySelector('[role="progressbar"]')).not.toBeNull();
});
