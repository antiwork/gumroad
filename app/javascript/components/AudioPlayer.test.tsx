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
