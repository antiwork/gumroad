import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import AdminProduct, { type Product } from "$app/components/Admin/Products/Product";
import AdminPurchase, { type Purchase } from "$app/components/Admin/Purchases";
import AdminUser, { type User } from "$app/components/Admin/Users/User";

type AdminPurchaseProps = {
  user: User;
  product: Product;
  purchase: Purchase;
};

const AdminPurchasesShow = () => {
  const { user, product, purchase } = cast<AdminPurchaseProps>(usePage().props);

  return (
    <div className="flex flex-col gap-4">
      <AdminPurchase purchase={purchase} />
      <AdminProduct product={product} />
      <AdminUser user={user} />
    </div>
  );
};

export default AdminPurchasesShow;
