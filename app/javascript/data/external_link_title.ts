import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

type ExternalLinkTitleResponse = { success: true; title: string } | { success: false };

export const getExternalLinkTitle = async (externalLinkUrl: string) => {
  const response = await request({
    method: "GET",
    url: Routes.external_link_title_path({ format: "json", url: externalLinkUrl }),
    accept: "json",
  });
  return cast<ExternalLinkTitleResponse>(await response.json());
};
