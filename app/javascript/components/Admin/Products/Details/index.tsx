import React from "react";
import { cast } from "ts-safe-cast";

import { useLazyFetch } from "$app/hooks/useLazyFetch";

import { type DetailsProps } from "$app/components/Admin/Products/AttributesAndInfo";
import AdminProductDetailsContent from "$app/components/Admin/Products/Details/Content";
import { type Product } from "$app/components/Admin/Products/Product";

type Props = {
  product: Product;
};

const AdminProductDetails = ({ product }: Props) => {
  const [open, setOpen] = React.useState(false);

  const {
    data: details,
    isLoading,
    fetchData: fetchDetails,
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions
  } = useLazyFetch<DetailsProps>({} as DetailsProps, {
    url: Routes.admin_product_details_path(product.id, { format: "json" }),
    responseParser: (data) => {
      const parsed = cast<{ details: DetailsProps }>(data);
      return parsed.details;
    },
  });

  const onToggle = (e: React.MouseEvent<HTMLDetailsElement>) => {
    setOpen(e.currentTarget.open);
    if (e.currentTarget.open) {
      void fetchDetails();
    }
  };

  return (
    <>
      <hr />
      <details open={open} onToggle={onToggle}>
        <summary>
          <h3>Details</h3>
        </summary>
        <AdminProductDetailsContent details={details} isLoading={isLoading} />
      </details>
    </>
  );
};

export default AdminProductDetails;
