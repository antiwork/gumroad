import { router, usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import AdminUsersProductsProduct, { type Product as ProductType } from "$app/components/Admin/Products/Product";
import AdminUserAndProductsTabs from "$app/components/Admin/UserAndProductsTabs";
import { Pagination, type PaginationProps } from "$app/components/Pagination";
import { Alert } from "$app/components/ui/Alert";

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
      <Alert role="status" variant="info">
        {isAffiliateUser ? "No affiliated products." : "No products created."}
      </Alert>
    );
  }

  return (
    <div className="space-y-4">
      {products.map((product) => (
        <AdminUsersProductsProduct key={product.external_id} product={product} isAffiliateUser={isAffiliateUser} />
      ))}
    </div>
  );
};

type Props = {
  isAffiliateUser?: boolean;
};

type AdminUsersProductsProps = {
  user: { external_id: string };
  products: ProductType[];
  pagination: PaginationProps;
};

const AdminUsersProducts = ({ isAffiliateUser = false }: Props) => {
  const { user, products, pagination } = cast<AdminUsersProductsProps>(usePage().props);
  const onChangePage = (page: number) => router.reload({ data: { page }, only: ["products", "pagination"] });

  return (
    <div className="flex flex-col gap-4">
      <AdminUserAndProductsTabs
        selectedTab="products"
        userExternalId={user.external_id}
        isAffiliateUser={isAffiliateUser}
      />
      <AdminUsersProductsContent products={products} isAffiliateUser={isAffiliateUser} pagination={pagination} />
      {pagination.pages > 1 && <Pagination pagination={pagination} onChangePage={onChangePage} />}
    </div>
  );
};

export default AdminUsersProducts;
