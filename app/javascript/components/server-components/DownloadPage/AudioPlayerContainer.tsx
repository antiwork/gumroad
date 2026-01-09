import { throttle } from "lodash-es";
import * as React from "react";

import { createConsumptionEvent } from "$app/data/consumption_analytics";
import { trackMediaLocationChanged } from "$app/data/media_location";

import { AudioPlayer } from "$app/components/AudioPlayer";
import { useMediaUrls, usePurchaseInfo } from "$app/components/server-components/DownloadPage/WithContent";

const LOCATION_TRACK_EVENT_DELAY = 10000;

export const AudioPlayerContainer = ({
  fileId,
  playingAudioForId,
  setPlayingAudioForId,
  resumeLocation,
  setResumeLocation,
  contentLength,
}: {
  fileId: string;
  playingAudioForId: null | string;
  setPlayingAudioForId: (id: null | string) => void;
  resumeLocation: number;
  setResumeLocation: (loc: number) => void;
  contentLength: number | null;
}) => {
  const { purchaseId, redirectId } = usePurchaseInfo();
  const [mediaUrls] = useMediaUrls();
  const [isPlaying, setIsPlaying] = React.useState(false);
  const [duration, setDuration] = React.useState(0);
  const mediaUrl = (mediaUrls[fileId] ?? [])[0];

  if (!mediaUrl) return null;

  React.useEffect(() => {
    if (playingAudioForId !== fileId) pauseAudio();
  }, [playingAudioForId]);

  const playAudio = () => {
    setIsPlaying(true);
    setPlayingAudioForId(fileId);
  };

  const pauseAudio = () => {
    setIsPlaying(false);
  };

  const updateProgress = React.useCallback(
    throttle((currentTime: number) => {
      if (purchaseId == null) return;
      setResumeLocation(currentTime);
      void trackMediaLocationChanged({
        urlRedirectId: redirectId,
        productFileId: fileId,
        purchaseId,
        location: contentLength !== null && currentTime > contentLength ? contentLength : currentTime,
      });
    }, LOCATION_TRACK_EVENT_DELAY),
    [],
  );

  const onEnded = () => {
    pauseAudio();
    updateProgress.cancel();
    if (purchaseId == null) return;
    void trackMediaLocationChanged({
      urlRedirectId: redirectId,
      productFileId: fileId,
      purchaseId,
      location: contentLength === null ? duration : contentLength,
    });
  };

  return (
    <AudioPlayer
      src={mediaUrl}
      isPlaying={isPlaying}
      onPlay={playAudio}
      onPause={pauseAudio}
      onTimeUpdate={updateProgress}
      onSeeked={(currentTime) => {
        if (!purchaseId) return;
        void trackMediaLocationChanged({
          urlRedirectId: redirectId,
          productFileId: fileId,
          purchaseId,
          location: contentLength !== null && currentTime > contentLength ? contentLength : currentTime,
        });
      }}
      onEnded={onEnded}
      onLoadedMetadata={(duration: number) => {
        setDuration(duration);
        void createConsumptionEvent({
          eventType: "listen",
          urlRedirectId: redirectId,
          productFileId: fileId,
          purchaseId,
        });
      }}
      startTime={resumeLocation}
    />
  );
};
