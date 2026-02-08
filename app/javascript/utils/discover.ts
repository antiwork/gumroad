import { cast, is } from "ts-safe-cast";

import { SearchRequest } from "$app/data/search";

const categoryImages = require.context("$assets/images/discover/");

export type Taxonomy = { key: string; slug: string; label: string; parent_key: string | null };

export function getRootTaxonomyCss(slug: RootTaxonomySlug) {
  return {
    backgroundColor: `var(--${rootTaxonomies[slug].color})`,
    color: "black",
    "--color": "0 0 0",
    "--color-border": "rgb(0 0 0 / 1)",
  };
}

export function getRootTaxonomyImage(slug: RootTaxonomySlug) {
  return cast<string>(categoryImages(`./${rootTaxonomies[slug].image}.svg`));
}

const rootTaxonomies = {
  "3d": { color: "green", image: "animation" },
  audio: { color: "red", image: "audio" },
  "business-and-money": { color: "green", image: "crafts" },
  "comics-and-graphic-novels": { color: "yellow", image: "comics" },
  design: { color: "orange", image: "design" },
  "drawing-and-painting": { color: "purple", image: "drawing" },
  education: { color: "yellow", image: "education" },
  "fiction-books": { color: "orange", image: "writing" },
  films: { color: "green", image: "film" },
  "fitness-and-health": { color: "orange", image: "sports" },
  gaming: { color: "orange", image: "games" },
  "music-and-sound-design": { color: "yellow", image: "music" },
  photography: { color: "green", image: "photography" },
  "recorded-music": { color: "yellow", image: "music" },
  "self-improvement": { color: "red", image: "dance" },
  "software-development": { color: "red", image: "software" },
  "writing-and-publishing": { color: "orange", image: "writing" },
  other: { color: "orange", image: "search" },
};
export type RootTaxonomySlug = keyof typeof rootTaxonomies;

export const getRootTaxonomy = (taxonomyPath: string | undefined) => {
  const root = taxonomyPath?.split("/")[0];
  return is<RootTaxonomySlug>(root) ? root : null;
};

export const discoverTitleGenerator = (params: SearchRequest, taxonomies: Taxonomy[]) => {
  const searchOrTagsTitle = params.query
    ? `Search results for “${params.query}”`
    : params.tags?.map((t) => t.trim().replace(/[-\s]+/gu, " ")).join(", ");
  const taxonomyTitle = params.taxonomy
    ?.split("/")
    .map((slug) => taxonomies.find((t) => t.slug === slug)?.label ?? slug)
    .join(" » ");
  return [searchOrTagsTitle, taxonomyTitle, "Gumroad"].filter((s) => s).join(" | ");
};
