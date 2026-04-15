import React from "react";
import { cast } from "ts-safe-cast";

import { useLazyFetch } from "$app/hooks/useLazyFetch";

import { type DetailsProps } from "$app/components/Admin/Products/AttributesAndInfo";
import AdminProductAttributesAndInfo from "$app/components/Admin/Products/AttributesAndInfo";
import { type Product } from "$app/components/Admin/Products/Product";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Details, DetailsToggle } from "$app/components/ui/Details";

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
    url: Routes.admin_product_details_path(product.external_id, { format: "json" }),
    responseParser: (data) => {
      const parsed = cast<{ details: DetailsProps }>(data);
      return parsed.details;
    },
  });

  const onToggle = (isOpen: boolean) => {
    setOpen(isOpen);
    if (isOpen) {
      void fetchDetails();
    }
  };

  return (
    <>
      <hr />
      <Details open={open} onToggle={onToggle}>
        <DetailsToggle>
          <h3>Details</h3>
        </DetailsToggle>
        {isLoading || !details ? <LoadingSpinner /> : <AdminProductAttributesAndInfo productData={details} />}
      </Details>
    </>
  );
};

export default AdminProductDetails;
