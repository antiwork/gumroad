import typia from "typia";

import { request } from "$app/utils/request";

export type Tag = { id: number; name: string; uses: number };

export async function getProductTags(data: { text: string }) {
  const response = await request({ method: "GET", url: Routes.tags_path(data), accept: "json" });
  return typia.assert<Tag[]>(await response.json());
}
