import { usePage } from "@inertiajs/react";
import React from "react";

import Product, { type Product as ProductType } from "$app/components/Admin/Products/Product";
import User, { type User as UserType } from "$app/components/Admin/Users/User";

type AdminProductProps = {
  user: UserType;
  product: ProductType;
};

const AdminProductsShow = () => {
  const { user, product } = usePage<AdminProductProps>().props;

  return (
    <div className="paragraphs">
      <Product key={product.id} product={product} />
      <User user={user} />
    </div>
  );
};

export default AdminProductsShow;
