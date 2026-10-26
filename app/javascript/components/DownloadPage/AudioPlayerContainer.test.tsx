// @vitest-environment happy-dom
import { act, cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import { trackMediaLocationChanged } from "$app/data/media_location";

import { AudioPlayer } from "$app/components/AudioPlayer";
import { AudioPlayerContainer } from "$app/components/DownloadPage/AudioPlayerContainer";
import { MediaUrlsProvider, PurchaseInfoProvider } from "$app/components/DownloadPage/WithContent";

vi.mock("$app/components/AudioPlayer", () => ({ AudioPlayer: vi.fn(() => null) }));
vi.mock("$app/data/media_location", () => ({ trackMediaLocationChanged: vi.fn() }));
vi.mock("$app/data/consumption_analytics", () => ({ createConsumptionEvent: vi.fn() }));

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.clearAllMocks();
});

const mountPlayer = (strict = false) => {
  const player = (
    <PurchaseInfoProvider value={{ purchaseId: "purchase-1", redirectId: "redirect-1", token: "token-1" }}>
      <MediaUrlsProvider value={[{ "file-1": ["https://example.com/audio.mp3"] }, vi.fn()]}>
        <AudioPlayerContainer
          fileId="file-1"
          playingAudioForId={null}
          setPlayingAudioForId={vi.fn()}
          resumeLocation={0}
          setResumeLocation={vi.fn()}
          contentLength={600}
        />
      </MediaUrlsProvider>
    </PurchaseInfoProvider>
  );
  return render(strict ? <React.StrictMode>{player}</React.StrictMode> : player);
};

const playerCallbacks = () => {
  const props = vi.mocked(AudioPlayer).mock.calls.at(-1)?.[0];
  if (!props) throw new Error("AudioPlayer was not rendered");
  return props;
};

it("cancels queued progress when the player closes instead of overwriting a reopened player's position", () => {
  vi.useFakeTimers();
  const first = mountPlayer();
  act(() => playerCallbacks().onTimeUpdate?.(10));
  act(() => playerCallbacks().onTimeUpdate?.(15));
  first.unmount();
  mountPlayer();
  act(() => playerCallbacks().onTimeUpdate?.(50));
  act(() => vi.advanceTimersByTime(10_001));
  expect(vi.mocked(trackMediaLocationChanged).mock.calls.map(([data]) => data.location)).toEqual([10, 50]);
});

it("keeps trailing progress updates while the player remains mounted", () => {
  vi.useFakeTimers();
  mountPlayer();
  act(() => playerCallbacks().onTimeUpdate?.(10));
  act(() => playerCallbacks().onTimeUpdate?.(15));
  act(() => vi.advanceTimersByTime(10_001));
  expect(vi.mocked(trackMediaLocationChanged).mock.calls.map(([data]) => data.location)).toEqual([10, 15]);
});

it("preserves completion without a later queued progress update", () => {
  vi.useFakeTimers();
  mountPlayer();
  act(() => playerCallbacks().onTimeUpdate?.(10));
  act(() => playerCallbacks().onTimeUpdate?.(15));
  act(() => playerCallbacks().onEnded?.());
  act(() => vi.advanceTimersByTime(10_001));
  expect(vi.mocked(trackMediaLocationChanged).mock.calls.map(([data]) => data.location)).toEqual([10, 600]);
});

it("tracks playback after Strict Mode replays effect cleanup and cancels it on final unmount", () => {
  vi.useFakeTimers();
  const player = mountPlayer(true);
  act(() => playerCallbacks().onTimeUpdate?.(10));
  act(() => playerCallbacks().onTimeUpdate?.(15));
  player.unmount();
  act(() => vi.advanceTimersByTime(10_001));
  expect(vi.mocked(trackMediaLocationChanged).mock.calls.map(([data]) => data.location)).toEqual([10]);
});

it("uses loaded metadata in the original throttled callback when content length is missing", () => {
  const setResumeLocation = vi.fn();
  render(
    <PurchaseInfoProvider value={{ purchaseId: "purchase-1", redirectId: "redirect-1", token: "token-1" }}>
      <MediaUrlsProvider value={[{ "file-1": ["https://example.com/audio.mp3"] }, vi.fn()]}>
        <AudioPlayerContainer
          fileId="file-1"
          playingAudioForId={null}
          setPlayingAudioForId={vi.fn()}
          resumeLocation={3690}
          setResumeLocation={setResumeLocation}
          contentLength={null}
        />
      </MediaUrlsProvider>
    </PurchaseInfoProvider>,
  );
  const initial = vi.mocked(AudioPlayer).mock.calls[0]?.[0];
  if (!initial) throw new Error("AudioPlayer was not rendered");
  act(() => initial.onLoadedMetadata?.(3711));
  act(() => initial.onTimeUpdate?.(3690));
  expect(setResumeLocation).toHaveBeenLastCalledWith(0);
  expect(trackMediaLocationChanged).toHaveBeenLastCalledWith(expect.objectContaining({ location: 3711 }));
  const loaded = vi.mocked(AudioPlayer).mock.calls.at(-1)?.[0];
  if (!loaded) throw new Error("AudioPlayer was not rendered");
  act(() => loaded.onSeeked?.(3690));
  expect(trackMediaLocationChanged).toHaveBeenLastCalledWith(expect.objectContaining({ location: 3711 }));
});
