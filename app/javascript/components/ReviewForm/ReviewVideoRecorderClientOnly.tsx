import cx from "classnames";
import React, { useEffect, useRef, useState } from "react";
import { useReactMediaRecorder } from "react-media-recorder";

import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import {
  ReviewVideoRecorderContainer,
  ReviewVideoRecorderProps,
  ReviewVideoRecorderUiState,
} from "$app/components/ReviewForm/ReviewVideoRecorderCommon";
import { ReviewVideoPlayer } from "$app/components/ReviewVideoPlayer";
import { showAlert } from "$app/components/server-components/Alert";

const MAX_RECORDING_DURATION_MS = 10 * 60 * 1000;

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
    <div className="absolute top-2 left-2 rounded-sm bg-red px-2 py-1 font-mono text-xs text-white">
      {pad(minutes)}:{pad(seconds)}
    </div>
  );
};

const disabledButtonClassNames = "cursor-not-allowed opacity-80";

const StartRecordingCountdownButton = ({ onClick, disabled }: { onClick: () => void; disabled?: boolean }) => (
  <button
    className={cx("absolute bottom-2 left-1/2 flex h-8 w-8 -translate-x-1/2 items-center justify-center rounded-full", {
      [disabledButtonClassNames]: disabled,
    })}
    onClick={onClick}
    disabled={disabled}
  >
    <div className="flex h-full w-full items-center justify-center rounded-full border-2 border-white p-[2px]">
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
    <div className="flex h-full w-full items-center justify-center rounded-full border-2 border-white p-[6px]">
      <div className="h-full w-full rounded-xs bg-red" />
    </div>
  </button>
);

const DeleteRecordingButton = ({ onClick, disabled }: { onClick: () => void; disabled?: boolean }) => (
  <button
    className={cx("absolute top-2 right-2 flex h-8 w-8 items-center justify-center rounded-sm bg-black", {
      [disabledButtonClassNames]: disabled,
    })}
    onClick={onClick}
    disabled={disabled}
  >
    <Icon name="trash2" className="text-sm text-white" />
  </button>
);

const LoadingOverlay = () => (
  <div className="absolute inset-0 flex items-center justify-center bg-black/40">
    <LoadingSpinner width="3em" />
  </div>
);

const ErrorOverlay = ({ message }: { message: string }) => (
  <div className="absolute inset-0 flex items-center justify-center bg-black/60">
    <p className="text-center text-red">{message}</p>
  </div>
);

const recordingType = MediaRecorder.isTypeSupported("video/webm") ? "video/webm" : "video/mp4";
const recordingExtension = recordingType === "video/webm" ? "webm" : "mp4";

export default function ReviewVideoRecorderClientOnly({
  formState,
  videoState,
  onVideoChange,
  onUiStateChange,
  disabled = false,
  reacquireStream,
}: ReviewVideoRecorderProps & {
  reacquireStream: () => void;
}) {
  const [uiState, setUiState] = useState<ReviewVideoRecorderUiState>("idle");
  const [askPermission, setAskPermission] = useState(false);

  const liveVideoRef = useRef<HTMLVideoElement | null>(null);
  const lastTrackId = useRef<string | null>(null);

  useEffect(() => {
    onUiStateChange?.(uiState);
  }, [uiState, onUiStateChange]);

  const setRecordedVideo = (blobUrl: string, blob: Blob) => {
    const videoFile = new File([blob], `video-review.${recordingExtension}`, { type: recordingType });
    onVideoChange({
      kind: "recorded",
      file: videoFile,
      url: blobUrl,
    });
  };

  const clearRecordedVideo = () => {
    if (videoState.kind === "existing") {
      onVideoChange({ kind: "deleted", id: videoState.id });
    } else {
      onVideoChange({ kind: "none" });
    }
    reacquireStream();
  };

  const {
    startRecording: startMediaRecorder,
    stopRecording: stopMediaRecorder,
    clearBlobUrl,
    mediaBlobUrl,
    previewStream,
    error,
    status,
  } = useReactMediaRecorder({
    audio: true,
    video: {
      aspectRatio: { ideal: 16 / 9 },
      width: { ideal: 1280, max: 1280 },
      height: { ideal: 720, max: 720 },
      frameRate: { ideal: 30, max: 30 },
    },
    askPermissionOnMount: askPermission,
    stopStreamsOnStop: true,
    blobPropertyBag: {
      type: recordingType,
    },
    onStop: setRecordedVideo,
  });

  const hasVideo = videoState.kind === "recorded" || videoState.kind === "existing";
  const loadingStream = status === "acquiring_media";
  const showLiveStream = !hasVideo && formState !== "viewing";

  const startRecording = () => {
    if (previewStream) {
      startMediaRecorder();
      setUiState("recording");
    }
  };

  const stopRecording = () => {
    stopMediaRecorder();
    setUiState("idle");
  };

  useEffect(() => {
    const el = liveVideoRef.current;
    if (!el || !previewStream) return;

    // Only re‑attach when the camera feed itself changes to avoid flickering.
    const [track] = previewStream.getVideoTracks();
    const id = track?.id;
    if (id && id !== lastTrackId.current) {
      el.srcObject = previewStream;
      lastTrackId.current = id;
    }
  }, [previewStream]);

  useEffect(() => {
    if (showLiveStream && !askPermission) {
      setAskPermission(true);
    }
  }, [showLiveStream, askPermission]);

  useEffect(() => {
    if (uiState === "recording") {
      const timer = setTimeout(() => {
        stopRecording();
        showAlert("Your recording has reached its maximum length and has been stopped.", "info");
      }, MAX_RECORDING_DURATION_MS);
      return () => clearTimeout(timer);
    }
  }, [uiState, stopRecording]);

  const renderUiState = () => {
    if (formState === "viewing" || loadingStream) {
      return null;
    }

    switch (uiState) {
      case "idle":
        return hasVideo ? (
          <DeleteRecordingButton
            onClick={() => {
              clearBlobUrl();
              clearRecordedVideo();
              setUiState("idle");
            }}
            disabled={disabled}
          />
        ) : (
          <StartRecordingCountdownButton onClick={() => setUiState("countdown")} disabled={disabled} />
        );
      case "countdown":
        return <CountdownOverlay initialCountdown={3} onCountdownFinish={startRecording} />;
      case "recording":
        return (
          <>
            <RecordingTimer />
            <StopRecordingButton onClick={stopRecording} disabled={disabled} />
          </>
        );
    }
  };

  const renderVideoPlayer = () => {
    if (videoState.kind === "recorded") {
      return (
        <video
          className="h-full w-full object-cover"
          key={mediaBlobUrl}
          src={mediaBlobUrl}
          controls={!disabled}
          autoPlay
          muted
        />
      );
    }
    if (videoState.kind === "existing") {
      return <ReviewVideoPlayer videoId={videoState.id} thumbnail={videoState.thumbnailUrl} />;
    }
    return null;
  };

  const renderLiveVideo = () => {
    if (error) {
      return <ErrorOverlay message={`Camera error: ${error}`} />;
    }
    if (loadingStream) {
      return <LoadingOverlay />;
    }
    return <video ref={liveVideoRef} autoPlay muted className="h-full w-full object-cover" />;
  };

  return (
    <ReviewVideoRecorderContainer>
      {showLiveStream ? renderLiveVideo() : renderVideoPlayer()}
      {renderUiState()}
    </ReviewVideoRecorderContainer>
  );
}
