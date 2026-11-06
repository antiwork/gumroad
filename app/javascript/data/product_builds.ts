import { cast } from "$app/utils/cast";
import { readJson, request, ResponseError } from "$app/utils/request";

export type ProductBuild = {
  id: string;
  number: number;
  status: "uploaded" | "live" | "superseded";
  byte_size: number;
  created_at: string;
  promoted_at: string | null;
  unpack_error?: string | null;
};

export const getProductBuilds = async (productPermalink: string) => {
  const response = await request({
    url: Routes.product_builds_path(productPermalink, "json"),
    method: "GET",
    accept: "json",
  });
  return (await readJson<{ builds: ProductBuild[] }>(response)).builds;
};

export const promoteProductBuild = async (productPermalink: string, buildId: string) => {
  const response = await request({
    url: Routes.promote_product_build_path(productPermalink, buildId, "json"),
    method: "POST",
    accept: "json",
  });
  if (!response.ok) throw new ResponseError();
};

// Records a zip the editor uploaded as a new version. The server's message says what was wrong with it.
export const createProductBuild = async (productPermalink: string, url: string) => {
  const response = await request({
    url: Routes.product_builds_path(productPermalink, "json"),
    method: "POST",
    accept: "json",
    data: { url },
  });
  if (!response.ok) {
    const json = cast<{ error?: string }>(await response.json().catch(() => ({})));
    throw new ResponseError(json.error);
  }
  return cast<{ build: ProductBuild }>(await response.json()).build;
};
