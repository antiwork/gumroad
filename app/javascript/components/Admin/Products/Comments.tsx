import React from "react";

import AdminCommentableComments from "$app/components/Admin/Commentable";
import type { Product } from "$app/components/Admin/Products/Product";

type AdminProductCommentsProps = {
  product: Product;
};

const AdminProductComments = ({ product }: AdminProductCommentsProps) => (
  <AdminCommentableComments
    count={product.comments_count}
    endpoint={Routes.admin_product_comments_path(product.external_id, { format: "json" })}
    commentableType="product"
  />
);

export default AdminProductComments;
