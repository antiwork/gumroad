import React, { useMemo } from "react";

import { type Product } from "$app/components/Admin/Products/Product";
import { Alert } from "$app/components/ui/Alert";
import { Details, DetailsToggle, DetailsContent } from "$app/components/ui/Details";

type Props = {
  product: Product;
};

const AdminUsersProductsDescription = ({ product }: Props) => {
  const strippedHtmlSafeDescription = useMemo(() => {
    if (!product.html_safe_description) return null;
    const tmp = document.createElement("div");
    tmp.innerHTML = product.html_safe_description;
    return tmp.textContent;
  }, []);

  return (
    <>
      <hr />
      <Details>
        <DetailsToggle>
          <h3>Description</h3>
        </DetailsToggle>
        <DetailsContent>
          {product.html_safe_description && strippedHtmlSafeDescription ? (
            <div dangerouslySetInnerHTML={{ __html: product.html_safe_description }} />
          ) : (
            <Alert role="status" variant="info">
              No description provided.
            </Alert>
          )}
        </DetailsContent>
      </Details>
    </>
  );
};

export default AdminUsersProductsDescription;
