import * as React from "react";

export type VideoState =
  | { kind: "none" }
  | { kind: "existing"; id: string; thumbnailUrl: string | null }
  | { kind: "recorded"; file: File; url: string }
  | { kind: "deleted"; id: string };

export type ReviewVideoRecorderUiState = "idle" | "countdown" | "recording";

export type ReviewVideoRecorderProps = {
  formState: "viewing" | "editing";
  videoState: VideoState;
  onVideoChange: (newVideoState: VideoState) => void;
  onUiStateChange?: (state: ReviewVideoRecorderUiState) => void;
  disabled?: boolean;
};

export const ReviewVideoRecorderContainer = ({ children }: { children?: React.ReactNode }) => (
  <div className="relative aspect-video w-full max-w-2xl overflow-hidden rounded-lg border border-black bg-black">
    {children}
  </div>
);
