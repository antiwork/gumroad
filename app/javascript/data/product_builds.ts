import { readJson, request, ResponseError } from "$app/utils/request";

export type ProductBuild = {
  id: string;
  number: number;
  status: "uploaded" | "live" | "superseded";
  byte_size: number;
  created_at: string;
  promoted_at: string | null;
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
