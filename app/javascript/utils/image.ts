import { cast } from "ts-safe-cast";

const readFileAsDataURL = (file: File): Promise<string> =>
  new Promise((resolve, reject) => {
    const reader = new FileReader();

    reader.addEventListener("load", () => {
      resolve(cast(reader.result));
    });

    reader.addEventListener("error", () => {
      reject(new Error());
    });

    reader.readAsDataURL(file);
  });

export const getImageDimensionsFromFile = (file: File): Promise<{ height: number; width: number }> =>
  readFileAsDataURL(file).then(getImageDimensionsFromURL);

export const getVideoDimensionsFromFile = (file: File): Promise<{ height: number; width: number }> =>
  new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const video = document.createElement("video");
    video.preload = "metadata";

        video.onloadedmetadata = () => {
      const dims = { width: video.videoWidth, height: video.videoHeight };
      URL.revokeObjectURL(url);
      resolve(dims);
    };

    video.onerror = (e) => {
      URL.revokeObjectURL(url);
      reject(e);
    };

    video.src = url;
  });

export const checkVideoHasAudio = (file: File): Promise<boolean> =>
  new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const video = document.createElement("video");
    video.preload = "metadata";

    video.onloadedmetadata = () => {
      // Check if video has audio using multiple methods for better browser compatibility
      let hasAudio = false;

      // Method 1: Check audioTracks property (most reliable)
      if ((video as any).audioTracks && (video as any).audioTracks.length > 0) {
        hasAudio = true;
      }
      // Method 2: Check if video has audio duration (fallback)
      else if (video.duration > 0 && !isNaN(video.duration)) {
        // For WebM files, if we can't detect audio tracks, assume it's silent
        // This is a conservative approach - we'd rather allow a silent video than reject it
        hasAudio = false;
      }
      URL.revokeObjectURL(url);
      resolve(hasAudio);
    };

    video.onerror = (e) => {
      URL.revokeObjectURL(url);
      reject(e);
    };

    video.src = url;
  });

export const getImageDimensionsFromURL = (fileUrl: string): Promise<{ height: number; width: number }> =>
  new Promise((resolve, reject) => {
    const img = new Image();

    img.onload = function () {
      resolve({ height: img.naturalHeight, width: img.naturalWidth });
    };

    img.onerror = function (_, __, ___, ____, error) {
      reject(error ?? new Error());
    };

    img.src = fileUrl;
  });
