import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

export type CircleCommunity = { name: string; id: number };

export type CircleSpaceGroup = { name: string; id: number };

type FetchCommunitiesSuccessResponse = { success: true; communities: CircleCommunity[] };

type FetchCommunitiesErrorResponse = { success: false };

type FetchSpaceGroupsSuccessResponse = { success: true; space_groups: CircleSpaceGroup[] };

type FetchSpaceGroupsErrorResponse = { success: false };

export const fetchCommunities = async (apiKey: string) => {
  const response = await request({
    method: "GET",
    url: Routes.communities_integrations_circle_index_path({ format: "json", api_key: apiKey }),
    accept: "json",
  });
  const responseData = cast<FetchCommunitiesSuccessResponse | FetchCommunitiesErrorResponse>(await response.json());
  if (!responseData.success) throw new ResponseError();
  return { communities: responseData.communities };
};

export const fetchSpaceGroups = async (apiKey: string, communityId: number) => {
  const response = await request({
    method: "GET",
    url: Routes.space_groups_integrations_circle_index_path({
      format: "json",
      api_key: apiKey,
      community_id: communityId,
    }),
    accept: "json",
  });
  const responseData = cast<FetchSpaceGroupsSuccessResponse | FetchSpaceGroupsErrorResponse>(await response.json());
  if (!responseData.success) throw new ResponseError();
  return { spaceGroups: responseData.space_groups };
};
