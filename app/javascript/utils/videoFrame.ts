// The video player boxes on the buyer content page and in the seller's content
// editor are both styled 16:9 by default (see `.embed > .preview` in
// stylesheets/_rich_text.scss). That is wrong for the growing number of sellers
// who film on a phone: a 1080x1920 portrait video gets fit into a landscape box,
// so they and their buyers see a thin strip of video between wide pillarbox bars
// and reasonably conclude the video "plays in landscape". When we know the
// video's real dimensions we shape the box to them instead.
// See https://github.com/antiwork/gumroad-private/issues/1392
//
// Portrait video also needs a height cap, or a 9:16 frame at full content width
// would be taller than the browser window and push everything else on the page
// out of view. We cap the height and let the box narrow to keep the aspect
// ratio, then centre it in the row.
//
// `svh` deliberately has no fallback: a browser that cannot parse it would drop
// the whole width declaration and collapse the box. Its support matches `dvh`,
// which every Inertia page already depends on for its full-height layout, and
// it matches `aspect-ratio` itself — so any browser that can shape the frame at
// all can also read this.
import type * as React from "react";

const MAX_PORTRAIT_PLAYER_HEIGHT = "80svh";

type VideoDimensions = { width?: number | null; height?: number | null };

/**
 * The inline style that shapes a video's player box to the video itself, or
 * `undefined` when we have no usable dimensions — in which case the caller keeps
 * the existing 16:9 box.
 */
export const videoFrameStyle = ({ width, height }: VideoDimensions): React.CSSProperties | undefined => {
  if (width == null || height == null || width <= 0 || height <= 0) return undefined;

  const style: React.CSSProperties = { aspectRatio: `${width} / ${height}` };
  if (height > width) {
    // Set an explicit width rather than a max-width: the frame is a grid item
    // whose children are absolutely positioned, so it has no intrinsic width of
    // its own, and the centring margins below suppress the grid's default
    // stretch — leaving a max-width alone would collapse the box to nothing.
    style.width = `min(100%, calc(${MAX_PORTRAIT_PLAYER_HEIGHT} * ${width} / ${height}))`;
    style.marginInline = "auto";
  }
  return style;
};

/**
 * The ratio to hand JW Player so it fills our (equally reshaped) container
 * instead of letterboxing itself into the 16:9 it falls back to when given no
 * ratio. Spread into the player's setup options; empty when dimensions are
 * unknown, leaving the player's own default in place.
 */
/**
 * Whether the frame has been made narrower than the 16:9 the thumbnails are
 * sized for — i.e. portrait. Only then should a still be letterboxed rather
 * than cropped to fill: on a 9:16 box "cover" would slice the top and bottom
 * off the subject. A landscape box keeps the original crop-to-fill, so a
 * seller thumbnail that does not match the video's ratio looks exactly as it
 * does today instead of gaining bands.
 */
export const videoFrameIsPortrait = ({ width, height }: VideoDimensions): boolean =>
  width != null && height != null && width > 0 && height > 0 && height > width;

export const videoPlayerAspectRatio = ({ width, height }: VideoDimensions): { aspectratio?: string } =>
  width != null && height != null && width > 0 && height > 0 ? { aspectratio: `${width}:${height}` } : {};
