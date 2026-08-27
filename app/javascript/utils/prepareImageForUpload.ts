import FileUtils from "$app/utils/file";

const DECODE_EXTENSIONS = ["heic", "heif", "avif", "bmp", "tif", "tiff", "jpeg", "jpg", "png", "webp", "gif"];
const DECODE_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/gif",
  "image/heic",
  "image/heif",
  "image/avif",
  "image/bmp",
  "image/x-bmp",
  "image/tiff",
  "image/tif",
]);
const PASSTHROUGH_TYPES = new Set(["image/jpeg", "image/png", "image/webp", "image/gif"]);
const ALPHA_TYPES = new Set(["image/png", "image/webp", "image/avif", "image/gif"]);
const ALPHA_EXTENSIONS = new Set(["png", "webp", "avif", "gif"]);
const DEFAULT_MAX_DIMENSION = 4096;
const DEFAULT_MAX_BYTES = 5 * 1024 * 1024;

export type PrepareImageOptions = {
  maxBytes?: number;
  maxDimension?: number;
};

const isHeicLike = (file: File): boolean => {
  const type = file.type.toLowerCase();
  const ext = FileUtils.getFileExtension(file.name).toLowerCase();
  return type === "image/heic" || type === "image/heif" || ext === "heic" || ext === "heif";
};

// Chrome/Firefox cannot decode HEIC. Safari can. Keep conversion off the
// unsupported browsers so the picker does not advertise a dead format.
export const heicDecodingLikely = (): boolean => {
  if (typeof navigator === "undefined") return true;
  const ua = navigator.userAgent || "";
  if (!ua) return true;
  return /safari/iu.test(ua) && !/chrome|crios|chromium|android|edg/iu.test(ua);
};

export const isLikelyImageFile = (file: File): boolean => {
  if (isHeicLike(file) && !heicDecodingLikely()) return false;
  // SVG/ICO/etc. are image/* but we cannot re-encode them; leave those to the
  // existing extension allow-lists so they still fail as invalid file types.
  if (DECODE_TYPES.has(file.type.toLowerCase())) return true;
  const ext = FileUtils.getFileExtension(file.name).toLowerCase();
  return DECODE_EXTENSIONS.includes(ext);
};

const loadImageElement = (url: string): Promise<HTMLImageElement> =>
  new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error("Could not decode image."));
    img.src = url;
  });

const decodeImage = async (file: File): Promise<ImageBitmap | HTMLImageElement> => {
  if (typeof createImageBitmap === "function") {
    try {
      return await createImageBitmap(file);
    } catch {
      // HEIC/AVIF often fail here in Chrome; try an <img> decode next.
    }
  }
  const url = URL.createObjectURL(file);
  try {
    return await loadImageElement(url);
  } finally {
    URL.revokeObjectURL(url);
  }
};

const canvasToBlob = (canvas: HTMLCanvasElement, type: string, quality: number): Promise<Blob> =>
  new Promise((resolve, reject) => {
    canvas.toBlob(
      (blob) => {
        if (!blob) reject(new Error("Could not encode image."));
        else resolve(blob);
      },
      type,
      quality,
    );
  });

const drawToCanvas = (source: ImageBitmap | HTMLImageElement, width: number, height: number): HTMLCanvasElement => {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("Could not encode image.");
  ctx.drawImage(source, 0, 0, width, height);
  return canvas;
};

const outputName = (name: string, ext: string): string => `${FileUtils.getFileNameWithoutExtension(name)}.${ext}`;

const preservesAlpha = (file: File, ext: string): boolean =>
  ALPHA_TYPES.has(file.type.toLowerCase()) || ALPHA_EXTENSIONS.has(ext);

export const prepareImageForUpload = async (file: File, options: PrepareImageOptions = {}): Promise<File> => {
  if (!isLikelyImageFile(file)) return file;

  const maxBytes = options.maxBytes ?? DEFAULT_MAX_BYTES;
  const maxDimension = options.maxDimension ?? DEFAULT_MAX_DIMENSION;
  const ext = FileUtils.getFileExtension(file.name).toLowerCase();
  const keepAnimatedGif = ext === "gif" || file.type === "image/gif";
  // Re-encoding a GIF collapses animation; leave it for the server allow-list.
  if (keepAnimatedGif) return file;

  const alreadyFine =
    PASSTHROUGH_TYPES.has(file.type) && file.size <= maxBytes && ext !== "heic" && ext !== "heif" && ext !== "avif";

  const source = await decodeImage(file);
  try {
    const srcWidth = "naturalWidth" in source ? source.naturalWidth : source.width;
    const srcHeight = "naturalHeight" in source ? source.naturalHeight : source.height;
    if (!srcWidth || !srcHeight) throw new Error("Could not decode image.");

    const largest = Math.max(srcWidth, srcHeight);
    const needsResize = largest > maxDimension || file.size > maxBytes;
    if (alreadyFine && !needsResize) return file;

    let width = srcWidth;
    let height = srcHeight;
    if (largest > maxDimension) {
      const scale = maxDimension / largest;
      width = Math.max(1, Math.round(srcWidth * scale));
      height = Math.max(1, Math.round(srcHeight * scale));
    }

    const keepAlpha = preservesAlpha(file, ext);
    const mime = keepAlpha ? "image/png" : "image/jpeg";
    let quality = 0.88;
    let blob: Blob | null = null;
    for (let attempt = 0; attempt < 8; attempt++) {
      const canvas = drawToCanvas(source, width, height);
      blob = await canvasToBlob(canvas, mime, keepAlpha ? 1 : quality);
      if (blob.size <= maxBytes) break;
      if (!keepAlpha && quality > 0.5) {
        quality -= 0.12;
      } else {
        width = Math.max(1, Math.round(width * 0.75));
        height = Math.max(1, Math.round(height * 0.75));
        quality = 0.82;
      }
    }
    if (!blob) throw new Error("Could not encode image.");

    return new File([blob], outputName(file.name, keepAlpha ? "png" : "jpg"), {
      type: mime,
      lastModified: Date.now(),
    });
  } finally {
    if ("close" in source) source.close();
  }
};

export const prepareImagesForUpload = async (
  files: readonly File[],
  options?: PrepareImageOptions,
): Promise<File[]> => {
  const out: File[] = [];
  for (const file of files) {
    out.push(isLikelyImageFile(file) ? await prepareImageForUpload(file, options) : file);
  }
  return out;
};
