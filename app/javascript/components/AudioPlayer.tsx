import { PauseCircle, PlayCircle, RotateCcw10, RotateCw10 } from "@boxicons/react";
import * as React from "react";

import { isResumableMediaLocation } from "$app/utils/mediaLocation";
import { asyncVoid } from "$app/utils/promise";

import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Range } from "$app/components/ui/Range";
import { useUserAgentInfo } from "$app/components/UserAgent";

type Props = {
  src: string;
  startTime?: number;
  contentLength?: number | null;
  onPlay?: () => void;
  onPlayRequest?: () => void;
  onPause?: () => void;
  onSeeked?: (currentTime: number) => void;
  onTimeUpdate?: (currentTime: number) => void;
  onEnded?: () => void;
  onLoadedMetadata?: (duration: number) => void;
  isPlaying?: boolean;
};

export const AudioPlayer = (props: Props) => {
  const userAgentInfo = useUserAgentInfo();
  const [isPlaying, setIsPlaying] = React.useState(false);
  const [isLoaded, setIsLoaded] = React.useState(false);
  // A file that fails to load or decode never fires loadedmetadata, so without
  // this the row spins forever. The error doesn't say which, so the copy can't either.
  const [hasError, setHasError] = React.useState(false);
  const [progress, setProgress] = React.useState(0);
  const [duration, setDuration] = React.useState(0);
  React.useEffect(() => {
    setHasError(false);
    setIsLoaded(false);
    setProgress(0);
    setDuration(0);
  }, [props.src]);
  const ref = React.useRef<HTMLAudioElement>(null);
  const playbackRequest = React.useRef(0);
  React.useEffect(() => {
    const audio = ref.current;
    return () => {
      playbackRequest.current += 1;
      audio?.pause();
    };
  }, [props.src]);

  const formattedTime = (num: number) => {
    num = Math.floor(num);
    const minutes = Math.floor(num / 60);
    const seconds = num % 60;
    const formatter = new Intl.NumberFormat(userAgentInfo.locale, { minimumIntegerDigits: 2 });
    return `${formatter.format(minutes)}:${formatter.format(seconds)}`;
  };

  React.useEffect(() => {
    if (props.isPlaying !== undefined)
      if (props.isPlaying) playAudio();
      else pauseAudio();
  }, [props.isPlaying]);

  const withAudio =
    <T extends unknown>(fn: (audio: HTMLAudioElement, ...args: T[]) => void) =>
    (...args: T[]) => {
      if (ref.current) fn(ref.current, ...args);
    };

  const playAudio = withAudio(
    asyncVoid(async (audio: HTMLAudioElement) => {
      const requestId = ++playbackRequest.current;
      try {
        await audio.play();
      } catch {
        // play() rejects for the same reasons the element's error event fires
        // (and on a pause race, which is not an error) — never let it escape.
        return;
      }
      if (requestId !== playbackRequest.current) return;
      setIsPlaying(true);
      props.onPlay?.();
    }),
  );

  const pauseAudio = withAudio((audio) => {
    playbackRequest.current += 1;
    audio.pause();
    setIsPlaying(false);
    props.onPause?.();
  });

  const rewind15 = withAudio((audio) => (audio.currentTime = Math.max(audio.currentTime - 15, 0)));

  const skip30 = withAudio((audio) => {
    audio.currentTime = Math.min(audio.currentTime + 30, audio.duration);
    if (audio.currentTime === audio.duration) pauseAudio();
  });

  const onTimeUpdate = withAudio((audio) => {
    setProgress(audio.currentTime);
    props.onTimeUpdate?.(audio.currentTime);
  });

  const onEnded = () => {
    pauseAudio();
    props.onEnded?.();
  };

  const onLoadedMetadata = withAudio((audio) => {
    setDuration(audio.duration);
    setIsLoaded(true);
    audio.currentTime = isResumableMediaLocation(props.startTime, props.contentLength ?? audio.duration)
      ? props.startTime
      : 0;
    if (props.isPlaying !== false) playAudio();
    props.onLoadedMetadata?.(audio.duration);
  });

  return (
    <div className="flex items-center justify-center gap-3">
      <audio
        src={props.src}
        ref={ref}
        preload="metadata"
        onTimeUpdate={onTimeUpdate}
        onSeeked={withAudio((audio) => props.onSeeked?.(audio.currentTime))}
        onEnded={onEnded}
        onLoadedMetadata={onLoadedMetadata}
        onError={() => setHasError(true)}
      />
      {hasError ? (
        <p className="text-[0.875rem] leading-[1.3]">This file couldn't be played.</p>
      ) : isLoaded ? (
        <>
          <div role="toolbar" className="flex items-center gap-2 text-[1.25rem]">
            {isPlaying ? (
              <button type="button" className="cursor-pointer all-unset" onClick={pauseAudio} aria-label="Pause">
                <PauseCircle className="size-5" />
              </button>
            ) : (
              <button
                type="button"
                className="cursor-pointer all-unset"
                onClick={() => {
                  props.onPlayRequest?.();
                  playAudio();
                }}
                aria-label="Play"
              >
                <PlayCircle className="size-5" />
              </button>
            )}
            <button type="button" className="cursor-pointer all-unset" onClick={rewind15} aria-label="Rewind15">
              <RotateCcw10 className="size-5" />
            </button>
            <button type="button" className="cursor-pointer all-unset" onClick={skip30} aria-label="Skip30">
              <RotateCw10 className="size-5" />
            </button>
          </div>
          <time aria-label="Progress" className="text-[0.875rem] leading-[1.3] tabular-nums">
            {formattedTime(progress)}
          </time>
          <Range
            min={0}
            step={0.01}
            value={progress}
            max={duration}
            onChange={withAudio(
              (audio, ev: React.ChangeEvent<HTMLInputElement>) => (audio.currentTime = Number(ev.target.value)),
            )}
            progress={(progress * 100) / duration}
            className="grow"
          />
          <time aria-label="Remaining" className="text-[0.875rem] leading-[1.3] tabular-nums">
            {formattedTime(duration - progress)}
          </time>
        </>
      ) : (
        <LoadingSpinner className="size-8" />
      )}
    </div>
  );
};
