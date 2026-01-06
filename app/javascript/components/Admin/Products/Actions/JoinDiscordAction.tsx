import React from "react";

import { type Product, type ActiveIntegration } from "$app/components/Admin/Products/Product";

type JoinDiscordActionProps = {
  product: Product;
};

const JoinDiscordAction = ({ product }: JoinDiscordActionProps) => {
  const hasDiscordIntegration = product.active_integrations.some(
    (integration: ActiveIntegration) => integration.type === "DiscordIntegration",
  );

  return (
    hasDiscordIntegration && (
      <a
        href={Routes.join_discord_redirect_admin_product_path(product.external_id)}
        className="button small"
        target="_blank"
        rel="noreferrer noopener"
      >
        Join Discord
      </a>
    )
  );
};

export default JoinDiscordAction;
