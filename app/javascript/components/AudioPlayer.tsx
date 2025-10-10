import * as React from "react";

import { asyncVoid } from "$app/utils/promise";

import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { useUserAgentInfo } from "$app/components/UserAgent";

type Props = {
  src: string;
  startTime?: number;
  onPlay?: () => void;
  onPause?: () => void;
  onSeeked?: (currentTime: number) => void;
  onTimeUpdate?: (currentTime: number) => void;
  onEnded?: () => void;
  onLoadedMetadata?: (duration: number) => void;
  isPlaying?: boolean;
};

export const AudioPlayer = (props: Props) => {
  const userAgentInfo = useUserAgentInfo();
  const [isPlaying, setIsPlaying] = React.useState(props.isPlaying ?? false);
  const [isLoaded, setIsLoaded] = React.useState(false);
  const [progress, setProgress] = React.useState(0);
  const [duration, setDuration] = React.useState(0);
  const ref = React.useRef<HTMLAudioElement>(null);

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
      await audio.play();
      setIsPlaying(true);
      props.onPlay?.();
    }),
  );

  const pauseAudio = withAudio((audio) => {
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
    audio.currentTime = props.startTime ?? 0;
    playAudio();
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
      />
      {isLoaded ? (
        <>
          <div role="toolbar" className="flex items-center gap-2 text-[1.25rem]">
            {isPlaying ? (
              <button type="button" onClick={pauseAudio} aria-label="Pause">
                <Icon name="circle-pause" />
              </button>
            ) : (
              <button type="button" onClick={playAudio} aria-label="Play">
                <Icon name="circle-play" />
              </button>
            )}
            <button type="button" onClick={rewind15} aria-label="Rewind15">
              <Icon name="skip-back-15" />
            </button>
            <button type="button" onClick={skip30} aria-label="Skip30">
              <Icon name="skip-forward-30" />
            </button>
          </div>
          <time aria-label="Progress" className="text-[0.875rem] leading-[1.3] tabular-nums">
            {formattedTime(progress)}
          </time>
          <input
            type="range"
            min={0}
            step={0.01}
            value={progress}
            max={duration}
            onChange={withAudio(
              (audio, ev: React.ChangeEvent<HTMLInputElement>) => (audio.currentTime = parseInt(ev.target.value, 10)),
            )}
            style={{ "--progress": `${(progress * 100) / duration}%` }}
            className="grow"
          />
          <time aria-label="Remaining" className="text-[0.875rem] leading-[1.3] tabular-nums">
            {formattedTime(duration - progress)}
          </time>
        </>
      ) : (
        <LoadingSpinner width="2em" />
      )}
    </div>
  );
};
