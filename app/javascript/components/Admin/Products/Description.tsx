import React from "react";

import { type Product } from "$app/components/Admin/Products/Product";

type Props = {
  product: Product;
};

const AdminUsersProductsDescription = ({ product }: Props) => (
  <>
    <hr />
    <details>
      <summary>
        <h3>Description</h3>
      </summary>
      {product.stripped_html_safe_description ? (
        <div dangerouslySetInnerHTML={{ __html: product.stripped_html_safe_description }} />
      ) : (
        <div className="info" role="status">
          No description provided.
        </div>
      )}
    </details>
  </>
);

export default AdminUsersProductsDescription;
