import { request, ResponseError } from "$app/utils/request";

export const stampProductFile = async ({
  purchaseInfoToken,
  productFileId,
}: {
  purchaseInfoToken: string;
  productFileId: string;
}) => {
  const response = await request({
    url: Routes.url_redirect_stamp_product_file_path(purchaseInfoToken, productFileId),
    method: "POST",
    accept: "json",
  });

  if (!response.ok) throw new ResponseError();
};
