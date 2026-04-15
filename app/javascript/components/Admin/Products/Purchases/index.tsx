import * as React from "react";
import { cast } from "ts-safe-cast";

import { useLazyPaginatedFetch } from "$app/hooks/useLazyFetch";

import { Details, DetailsToggle } from "$app/components/ui/Details";

import AdminProductPurchasesContent from "./Content";
import { type ProductPurchase } from "./Purchase";

type AdminProductPurchasesProps = {
  productExternalId: string;
  isAffiliateUser?: boolean;
  userExternalId: string | null;
};

const AdminProductPurchases = ({
  productExternalId,
  isAffiliateUser = false,
  userExternalId,
}: AdminProductPurchasesProps) => {
  const [open, setOpen] = React.useState(false);

  const url =
    userExternalId && isAffiliateUser
      ? Routes.admin_affiliate_product_purchases_path(userExternalId, productExternalId, { format: "json" })
      : Routes.admin_product_purchases_path(productExternalId, { format: "json" });

  const {
    data: purchases,
    isLoading,
    fetchNextPage,
    hasMore,
  } = useLazyPaginatedFetch<ProductPurchase[]>([], {
    fetchUnlessLoaded: open,
    url,
    responseParser: (data) => {
      const parsed = cast<{ purchases: ProductPurchase[] }>(data);
      return parsed.purchases;
    },
    mode: "append",
  });

  return (
    <>
      <hr />
      <Details open={open} onToggle={setOpen}>
        <DetailsToggle>
          <h3>{isAffiliateUser ? "Affiliate purchases" : "Purchases"}</h3>
        </DetailsToggle>
        <AdminProductPurchasesContent
          purchases={purchases}
          isLoading={isLoading}
          hasMore={hasMore}
          onLoadMore={() => void fetchNextPage()}
          productExternalId={productExternalId}
        />
      </Details>
    </>
  );
};

export default AdminProductPurchases;
