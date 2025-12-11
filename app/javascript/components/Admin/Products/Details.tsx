import React from "react";
import { cast } from "ts-safe-cast";

import { useLazyFetch } from "$app/hooks/useLazyFetch";

import { type DetailsProps } from "$app/components/Admin/Products/AttributesAndInfo";
import AdminProductAttributesAndInfo from "$app/components/Admin/Products/AttributesAndInfo";
import { type Product } from "$app/components/Admin/Products/Product";
import { LoadingSpinner } from "$app/components/LoadingSpinner";

type Props = {
  product: Product;
};

const AdminProductDetails = ({ product }: Props) => {
  const [open, setOpen] = React.useState(false);

  const {
    data: details,
    isLoading,
    fetchData: fetchDetails,
  } = useLazyFetch<DetailsProps | null>(null, {
    fetchUnlessLoaded: open,
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
        {isLoading || !details ? <LoadingSpinner /> : <AdminProductAttributesAndInfo productData={details} />}
      </details>
    </>
  );
};

export default AdminProductDetails;
