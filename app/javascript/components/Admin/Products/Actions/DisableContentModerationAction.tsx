import React from "react";

import { AdminActionButton } from "$app/components/Admin/ActionButton";
import { type Product } from "$app/components/Admin/Products/Product";

type DisableContentModerationActionProps = {
  product: Product;
};

const DisableContentModerationAction = ({ product }: DisableContentModerationActionProps) =>
  product.content_moderation_disabled ? (
    <AdminActionButton
      url={Routes.set_content_moderation_disabled_admin_product_path(product.external_id, { disabled: "false" })}
      label="Enable content moderation"
      loading="Enabling content moderation..."
      done="Content moderation enabled!"
      success_message="Content moderation enabled!"
    />
  ) : (
    <AdminActionButton
      url={Routes.set_content_moderation_disabled_admin_product_path(product.external_id, { disabled: "true" })}
      label="Disable content moderation"
      loading="Disabling content moderation..."
      done="Content moderation disabled!"
      success_message="Content moderation disabled!"
    />
  );

export default DisableContentModerationAction;
