import cx from "classnames";
import React, { useEffect, useRef, useState } from "react";
import { useReactMediaRecorder } from "react-media-recorder";

import { Icon } from "$app/components/Icons";
import { VideoReviewContainer, VideoReviewProps } from "$app/components/ReviewForm/VideoReviewCommon";

const CountdownOverlay = ({
  initialCountdown,
  onCountdownFinish,
}: {
  initialCountdown: number;
  onCountdownFinish: () => void;
}) => {
  const [count, setCount] = useState(initialCountdown);

  useEffect(() => {
    if (count > 0) {
      const timer = setTimeout(() => setCount(count - 1), 1000);
      return () => clearTimeout(timer);
    }
    onCountdownFinish();
  }, [count, onCountdownFinish]);

  return (
    <div className="absolute inset-0 flex items-center justify-center bg-black/40">
      <span className="text-7xl font-bold text-white">{count}</span>
    </div>
  );
};

const RecordingTimer = () => {
  const [startedAt] = useState(Date.now());

  // To trigger re-renders.
  const [_, setTick] = useState(0);

  useEffect(() => {
    const timerId = setInterval(() => {
      setTick((prev) => prev + 1);
    }, 1000);
    return () => clearInterval(timerId);
  }, []);

  const elapsedSeconds = Math.floor((Date.now() - startedAt) / 1000);
  const minutes = Math.floor(elapsedSeconds / 60);
  const seconds = elapsedSeconds % 60;
  const pad = (num: number) => num.toString().padStart(2, "0");

  return (
    <div className="absolute left-2 top-2 rounded bg-red px-2 py-1 text-xs text-white">
      {pad(minutes)}:{pad(seconds)}
    </div>
  );
};

const disabledButtonClassNames = "cursor-not-allowed opacity-80";

const StartRecordingButton = ({ onClick, disabled }: { onClick: () => void; disabled?: boolean }) => (
  <button
    className={cx("absolute bottom-2 left-1/2 flex h-8 w-8 -translate-x-1/2 items-center justify-center rounded-full", {
      [disabledButtonClassNames]: disabled,
    })}
    onClick={onClick}
    disabled={disabled}
  >
    <div className="flex h-full w-full items-center justify-center rounded-full border-[2px] border-white p-[2px]">
      <div className="h-full w-full rounded-full bg-red" />
    </div>
  </button>
);

const StopRecordingButton = ({ onClick, disabled }: { onClick: () => void; disabled?: boolean }) => (
  <button
    className={cx("absolute bottom-2 left-1/2 flex h-8 w-8 -translate-x-1/2 items-center justify-center rounded-full", {
      [disabledButtonClassNames]: disabled,
    })}
    onClick={onClick}
    disabled={disabled}
  >
    <div className="flex h-full w-full items-center justify-center rounded-full border-[2px] border-white p-[6px]">
      <div className="h-full w-full rounded-sm bg-red" />
    </div>
  </button>
);

const DeleteRecordingButton = ({ onClick, disabled }: { onClick: () => void; disabled?: boolean }) => (
  <button
    className={cx("absolute right-2 top-2 flex h-8 w-8 items-center justify-center rounded bg-black", {
      [disabledButtonClassNames]: disabled,
    })}
    onClick={onClick}
    disabled={disabled}
  >
    <Icon name="trash2" className="text-sm text-white" />
  </button>
);

export default function VideoReviewClientOnly({
  formState,
  videoUrl,
  onVideoChange,
  disabled = false,
}: VideoReviewProps) {
  const [uiState, setUiState] = useState<"idle" | "countdown" | "recording" | "preview">("idle");
  const liveVideoRef = useRef<HTMLVideoElement | null>(null);
  const [originalVideoUrl, setOriginalVideoUrl] = useState<string | null>(videoUrl);

  const setRecordedVideo = (_blobUrl: string, blob: Blob) => {
    const videoFile = new File([blob], "video-review.webm", { type: "video/webm" });
    onVideoChange(videoFile);
  };

  const clearRecordedVideo = () => {
    onVideoChange(null);
    setOriginalVideoUrl(null);
  };

  const { startRecording, stopRecording, clearBlobUrl, mediaBlobUrl, previewStream } = useReactMediaRecorder({
    audio: true,
    video: true,
    askPermissionOnMount: true,
    stopStreamsOnStop: true,
    blobPropertyBag: {
      type: "video/webm",
    },
    onStop: setRecordedVideo,
  });

  useEffect(() => {
    if (liveVideoRef.current && previewStream) {
      liveVideoRef.current.srcObject = previewStream;
    }
  }, [previewStream]);

  if (formState === "viewing") {
    const source = mediaBlobUrl || originalVideoUrl;
    if (source) {
      return (
        <div className="w-full">
          <video className="w-full rounded-lg" src={source} controls={!disabled} />
        </div>
      );
    }
    return null;
  }

  const renderUiState = () => {
    switch (uiState) {
      case "idle":
        return (
          <StartRecordingButton
            onClick={() => {
              setUiState("countdown");
            }}
            disabled={disabled}
          />
        );
      case "countdown":
        return (
          <CountdownOverlay
            initialCountdown={3}
            onCountdownFinish={() => {
              if (previewStream) {
                startRecording();
                setUiState("recording");
              }
            }}
          />
        );
      case "recording":
        return (
          <>
            <RecordingTimer />
            <StopRecordingButton
              onClick={() => {
                stopRecording();
                setUiState("preview");
              }}
              disabled={disabled}
            />
          </>
        );
      case "preview":
        return (
          <DeleteRecordingButton
            onClick={() => {
              clearBlobUrl();
              clearRecordedVideo();
              setUiState("idle");
            }}
            disabled={disabled}
          />
        );
    }
  };

  return (
    <VideoReviewContainer>
      <video
        ref={liveVideoRef}
        autoPlay
        muted
        className={cx("h-full w-full object-cover", { hidden: uiState === "preview" })}
      />
      <video
        className={cx("h-full w-full object-cover", { hidden: uiState !== "preview" })}
        src={mediaBlobUrl || originalVideoUrl || undefined}
        controls={!disabled}
        autoPlay
        muted
      />
      {renderUiState()}
    </VideoReviewContainer>
  );
}
