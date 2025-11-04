import { usePage } from "@inertiajs/react";
import React from "react";

import Product, { type Product as ProductType } from "$app/components/Admin/Products/Product";
import Purchase, { type Purchase as PurchaseType } from "$app/components/Admin/Purchase";
import User, { type User as UserType } from "$app/components/Admin/Users/User";

type AdminPurchaseProps = {
  user: UserType;
  product: ProductType;
  purchase: PurchaseType;
};

const AdminPurchasesShow = () => {
  const { user, product, purchase } = usePage<AdminPurchaseProps>().props;

  return (
    <div className="paragraphs">
      <Purchase purchase={purchase} />
      <Product key={product.id} product={product} isAffiliateUser={false} />
      <User user={user} />
    </div>
  );
};

export default AdminPurchasesShow;
