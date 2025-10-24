import React from "react";

import Loading from "$app/components/Admin/Loading";

import AdminProductPurchase, { ProductPurchase } from "./Purchase";

type AdminProductPurchasesContentProps = {
  purchases: ProductPurchase[];
  isLoading: boolean;
  hasMore: boolean;
  onLoadMore: () => void;
};

const AdminProductPurchasesContent = ({
  purchases,
  isLoading,
  hasMore,
  onLoadMore,
}: AdminProductPurchasesContentProps) => {
  const handleClick = (e: React.MouseEvent<HTMLButtonElement>) => {
    e.preventDefault();
    if (hasMore) {
      onLoadMore();
    }
  };

  if (purchases.length === 0 && !isLoading)
    return (
      <div className="info" role="status">
        No purchases have been made.
      </div>
    );

  return (
    <div className="paragraphs">
      <div className="stack">
        {purchases.map((purchase) => (
          <AdminProductPurchase key={purchase.id} purchase={purchase} />
        ))}
      </div>

      {isLoading ? <Loading /> : null}

      {hasMore ? (
        <button className="button small" onClick={handleClick} disabled={isLoading}>
          {isLoading ? "Loading..." : "Load more"}
        </button>
      ) : null}
    </div>
  );
};

export default AdminProductPurchasesContent;
