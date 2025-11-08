import { router, usePage } from "@inertiajs/react";
import React from "react";

import AdminUsersProductsProduct, { type Product as ProductType } from "$app/components/Admin/Products/Product";
import AdminUserAndProductsTabs from "$app/components/Admin/UserAndProductsTabs";
import { type User as UserType } from "$app/components/Admin/Users/User";
import { Pagination, type PaginationProps } from "$app/components/Pagination";

type AdminUsersProductsContentProps = {
  products: ProductType[];
  isAffiliateUser?: boolean;
  pagination: PaginationProps;
};

const AdminUsersProductsContent = ({
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
        <AdminUsersProductsProduct key={product.id} product={product} isAffiliateUser={isAffiliateUser} />
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
  pagination: PaginationProps;
};

const AdminUsersProducts = ({ isAffiliateUser = false }: Props) => {
  const { user, products, pagination } = usePage<AdminUsersProductsProps>().props;
  const onChangePage = (page: number) => router.reload({ data: { page }, only: ["products", "pagination"] });

  return (
    <div className="paragraphs">
      <AdminUserAndProductsTabs selectedTab="products" userId={user.id} />
      <AdminUsersProductsContent products={products} isAffiliateUser={isAffiliateUser} pagination={pagination} />
      {pagination.pages > 1 && <Pagination pagination={pagination} onChangePage={onChangePage} />}
    </div>
  );
};

export default AdminUsersProducts;
