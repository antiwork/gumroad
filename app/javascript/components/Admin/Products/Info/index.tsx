import React from "react";
import { cast } from "ts-safe-cast";

import { useLazyFetch } from "$app/hooks/useLazyFetch";

import AdminProductInfoContent from "$app/components/Admin/Products/Info/Content";
import { type InfoProps } from "$app/components/Admin/Products/Info/Content";
import { type Product } from "$app/components/Admin/Products/Product";

type Props = {
  product: Product;
};

const AdminProductInfo = ({ product }: Props) => {
  const [open, setOpen] = React.useState(false);

  const {
    data: info,
    isLoading,
    fetchData: fetchInfo,
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions
  } = useLazyFetch<InfoProps>({} as InfoProps, {
    url: Routes.admin_product_info_path(product.id, { format: "json" }),
    responseParser: (data) => {
      const parsed = cast<{ info: InfoProps }>(data);
      return parsed.info;
    },
  });

  const onToggle = (e: React.MouseEvent<HTMLDetailsElement>) => {
    setOpen(e.currentTarget.open);
    if (e.currentTarget.open) {
      void fetchInfo();
    }
  };

  return (
    <>
      <hr />
      <details open={open} onToggle={onToggle}>
        <summary>
          <h3>Info</h3>
        </summary>
        <AdminProductInfoContent info={info} isLoading={isLoading} />
      </details>
    </>
  );
};

export default AdminProductInfo;
