import React from "react";
import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

import AdminProductInfoContent from "$app/components/Admin/Products/Info/Content";
import { type InfoProps } from "$app/components/Admin/Products/Info/Content";
import { type Product } from "$app/components/Admin/Products/Product";
import { useIsIntersecting } from "$app/components/useIsIntersecting";

type Props = {
  product: Product;
};

const AdminProductInfo = ({ product }: Props) => {
  const [isLoading, setIsLoading] = React.useState(false);
  const [info, setInfo] = React.useState<InfoProps | null>(null);

  const elementRef = useIsIntersecting<HTMLDivElement>((isIntersecting) => {
    if (!isIntersecting || info) return;

    const fetchInfo = async () => {
      setIsLoading(true);
      const response = await request({
        method: "GET",
        url: Routes.admin_product_info_path(product.id, { format: "json" }),
        accept: "json",
      });
      const data = cast<{ info: InfoProps }>(await response.json());
      setInfo(data.info);
      setIsLoading(false);
    };

    void fetchInfo();
  });

  return (
    <div ref={elementRef} className="border-t border-border pt-4">
      <h3 className="mb-4">Info</h3>
      <AdminProductInfoContent info={info} isLoading={isLoading} />
    </div>
  );
};

export default AdminProductInfo;
