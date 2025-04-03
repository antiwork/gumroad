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
