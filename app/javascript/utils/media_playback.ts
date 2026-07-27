// The buyer content ("download") page asks the server for updated media positions every 10
// seconds so the progress bars next to each file stay current. While a video is actually
// playing that read is redundant: the player itself reports the buyer's position to the server
// every 10 seconds, so the only thing the poll adds is another long-lived stream of background
// requests that runs for as long as the buyer keeps the page open. Long viewing sessions are
// exactly where that has hurt before — a single background request that comes back as something
// other than an Inertia response tears the page down and the buyer loses their place
// (https://github.com/antiwork/gumroad/issues/4007).
//
// The player sits several components below the page component, so instead of threading a
// callback through the whole content tree it broadcasts its playback state on the window and
// the page listens for it.
export const MEDIA_PLAYBACK_EVENT = "gumroad:media_playback";

export type MediaPlaybackEventDetail = { isPlaying: boolean };

export const dispatchMediaPlaybackState = (isPlaying: boolean) =>
  window.dispatchEvent(new CustomEvent<MediaPlaybackEventDetail>(MEDIA_PLAYBACK_EVENT, { detail: { isPlaying } }));

export const isMediaPlaybackEvent = (event: Event): event is CustomEvent<MediaPlaybackEventDetail> => {
  if (!(event instanceof CustomEvent)) return false;
  const detail: unknown = event.detail;
  return typeof detail === "object" && detail !== null && typeof Reflect.get(detail, "isPlaying") === "boolean";
};
