import React from "react";

import EmptyState from "$app/components/Admin/EmptyState";
import { AdminPurchase, type Purchase } from "$app/components/Admin/Purchase";

type CardsPageProps = {
  purchases: Purchase[];
};

const CardsPage = ({ purchases }: CardsPageProps) => {
  if (purchases.length === 0) {
    return <EmptyState message="No purchases found." />;
  }

  return (
    <div className="paragraphs">
      {purchases.map((purchase) => (
        <AdminPurchase key={purchase.id} purchase={purchase} />
      ))}
    </div>
  );
};

export default CardsPage;
