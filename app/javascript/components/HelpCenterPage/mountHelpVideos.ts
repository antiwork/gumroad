import { trackHelpVideoEvent } from "$app/data/google_analytics";
import { createJWPlayer } from "$app/utils/jwPlayer";

const PROGRESS_MARKS = [25, 50, 75] as const;

type Player = Awaited<ReturnType<typeof createJWPlayer>>;

type Mount = {
  cancelled: boolean;
  player: Player | null;
};

export function mountHelpVideos(root: HTMLElement): () => void {
  const mounts: Mount[] = [];

  root.querySelectorAll<HTMLElement>("[data-help-video]").forEach((el, index) => {
    const src = el.dataset.helpVideoSrc;
    const videoId = el.dataset.helpVideo;
    const title = el.dataset.helpVideoTitle ?? videoId ?? "Help video";
    const poster = el.dataset.helpVideoPoster;
    if (!src || !videoId) return;

    const state: Mount = { cancelled: false, player: null };
    mounts.push(state);

    const playerId = el.id || `help-video-${index}`;
    el.id = playerId;
    el.classList.add("aspect-video", "w-full", "overflow-hidden", "rounded-sm", "bg-black");

    const firedProgress = new Set<number>();
    let started = false;

    void createJWPlayer(playerId, {
      width: "100%",
      aspectratio: "16:9",
      playlist: [
        {
          sources: [{ file: src }],
          title,
          image: poster,
        },
      ],
    }).then((player) => {
      if (state.cancelled) {
        player.remove();
        return;
      }
      state.player = player;

      player.on("play", () => {
        if (started) return;
        started = true;
        trackHelpVideoEvent("video_start", { videoId, title, url: src });
      });

      player.on("time", (event: { position: number; duration: number }) => {
        if (!event.duration) return;
        const percent = Math.floor((event.position / event.duration) * 100);
        for (const mark of PROGRESS_MARKS) {
          if (percent >= mark && !firedProgress.has(mark)) {
            firedProgress.add(mark);
            trackHelpVideoEvent("video_progress", { videoId, title, url: src, percent: mark });
          }
        }
      });

      player.on("complete", () => {
        trackHelpVideoEvent("video_complete", { videoId, title, url: src, percent: 100 });
      });
    });
  });

  return () => {
    for (const state of mounts) {
      state.cancelled = true;
      state.player?.remove();
      state.player = null;
    }
  };
}
