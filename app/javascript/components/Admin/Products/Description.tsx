import React, { useMemo } from "react";

import { type Product } from "$app/components/Admin/Products/Product";

type Props = {
  product: Product;
};

const AdminUsersProductsDescription = ({ product }: Props) => {
  const strippedHtmlSafeDescription = useMemo(() => {
    if (!product.html_safe_description) return null;
    const tmp = document.createElement("div");
    tmp.innerHTML = product.html_safe_description;
    return tmp.textContent;
  }, [product.html_safe_description]);

  return (
    <>
      <hr />
      <details>
        <summary>
          <h3>Description</h3>
        </summary>
        {strippedHtmlSafeDescription ? (
          <div>{strippedHtmlSafeDescription}</div>
        ) : (
          <div className="info" role="status">
            No description provided.
          </div>
        )}
      </details>
    </>
  );
};

export default AdminUsersProductsDescription;
