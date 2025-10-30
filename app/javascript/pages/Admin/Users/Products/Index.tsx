import { usePage } from "@inertiajs/react";
import React from "react";

import { type Pagination } from "$app/hooks/useLazyFetch";

import PaginatedLoader from "$app/components/Admin/PaginatedLoader";
import AdminUsersProductsProduct, { type Product as ProductType } from "$app/components/Admin/Products/Product";
import AdminUserAndProductsTabs from "$app/components/Admin/UserAndProductsTabs";
import { type User as UserType } from "$app/components/Admin/Users/User";

type AdminUsersProductsContentProps = {
  user: UserType;
  products: ProductType[];
  isAffiliateUser?: boolean;
  pagination: Pagination;
};

const AdminUsersProductsContent = ({
  user,
  products,
  isAffiliateUser = false,
  pagination,
}: AdminUsersProductsContentProps) => {
  if (pagination.page === 1 && products.length === 0) {
    return (
      <div className="info" role="status">
        No products created.
      </div>
    );
  }

  return (
    <div className="space-y-4">
      {products.map((product) => (
        <AdminUsersProductsProduct key={product.id} user={user} product={product} isAffiliateUser={isAffiliateUser} />
      ))}
    </div>
  );
};

type Props = {
  isAffiliateUser?: boolean;
};

type AdminUsersProductsProps = {
  user: UserType;
  products: ProductType[];
  pagination: Pagination;
};

const AdminUsersProducts = ({ isAffiliateUser = false }: Props) => {
  const { user, products, pagination } = usePage<AdminUsersProductsProps>().props;

  return (
    <div className="paragraphs">
      <AdminUserAndProductsTabs selectedTab="products" user={user} />
      <AdminUsersProductsContent
        user={user}
        products={products}
        isAffiliateUser={isAffiliateUser}
        pagination={pagination}
      />
      <PaginatedLoader itemsLength={products.length} pagination={pagination} only={["products", "pagination"]} />
    </div>
  );
};

export default AdminUsersProducts;
