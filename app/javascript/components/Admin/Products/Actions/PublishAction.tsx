import React from "react";

import { AdminActionButton } from "$app/components/Admin/ActionButton";
import { type Product } from "$app/components/Admin/Products/Product";

type PublishActionProps = {
  product: Product;
};

const PublishAction = ({ product }: PublishActionProps) =>
  product.alive ? (
    <AdminActionButton
      url={Routes.unpublish_admin_link_path(product.unique_permalink)}
      label="Unpublish"
      loading="Unpublishing..."
      done="Unpublished!"
      success_message="Unpublished!"
    />
  ) : (
    <AdminActionButton
      url={Routes.publish_admin_link_path(product.unique_permalink)}
      label="Publish"
      loading="Publishing..."
      done="Published!"
      success_message="Published!"
    />
  );

export default PublishAction;
