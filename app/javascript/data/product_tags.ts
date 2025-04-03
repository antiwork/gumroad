import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

export type Tag = { id: number; name: string; uses: number };

export async function getProductTags(data: { text: string }) {
  const response = await request({ method: "GET", url: Routes.tags_path(data), accept: "json" });
  return cast<Tag[]>(await response.json());
}
