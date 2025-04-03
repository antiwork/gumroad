import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

export type Follower = {
  id: string;
  email: string;
  created_at: string;
  source: string | null;
  formatted_confirmed_on: string;
  can_update: boolean | null;
};

export async function fetchFollowers(data: { email: string; page: number }) {
  const response = await request({ method: "GET", url: Routes.search_followers_path(data), accept: "json" });
  if (!response.ok) throw new Error("Server returned error response");
  return cast<{ paged_followers: Follower[]; total_count: number }>(await response.json());
}

export async function deleteFollower(id: string) {
  const response = await request({ method: "DELETE", url: Routes.follower_path({ id }), accept: "json" });
  if (!response.ok) throw new Error("Server returned error response");
}
