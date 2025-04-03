import * as React from "react";
export type VideoReviewProps = {
  formState: "viewing" | "editing";
  videoUrl: string | null;
};

export const VideoReviewContainer = ({ children }: { children?: React.ReactNode }) => (
  <div className="relative aspect-video w-full max-w-2xl overflow-hidden rounded-lg border border-black bg-black">
    {children}
  </div>
);
