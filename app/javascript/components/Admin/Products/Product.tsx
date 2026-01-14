import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import AdminProductActions from "$app/components/Admin/Products/Actions";
import AdminProductComments from "$app/components/Admin/Products/Comments";
import AdminProductDescription from "$app/components/Admin/Products/Description";
import AdminProductDetails from "$app/components/Admin/Products/Details";
import { type Compliance } from "$app/components/Admin/Products/FlagForTosViolations";
import AdminFlagForTosViolations from "$app/components/Admin/Products/FlagForTosViolations";
import AdminProductFooter from "$app/components/Admin/Products/Footer";
import AdminProductHeader from "$app/components/Admin/Products/Header";
import AdminProductInfo from "$app/components/Admin/Products/Info";
import AdminProductPurchases from "$app/components/Admin/Products/Purchases";

type ProductFile = {
  external_id: string;
  s3_filename: string | null;
};

export type ActiveIntegration = {
  type: string;
};

export type ProductUser = {
  external_id: string;
  name: string | null;
  suspended: boolean;
  flagged_for_tos_violation: boolean;
};

export type Product = {
  external_id: string;
  name: string;
  long_url: string;
  price_cents: number;
  currency_code: string;
  unique_permalink: string;
  preview_url: string | null;
  cover_placeholder_url: string;
  price_formatted: string;
  created_at: string;
  user: ProductUser;
  admins_can_generate_url_redirects: boolean;
  alive_product_files: ProductFile[];
  html_safe_description: string | null;
  alive: boolean;
  is_adult: boolean;
  active_integrations: ActiveIntegration[];
  admins_can_mark_as_staff_picked: boolean;
  admins_can_unmark_as_staff_picked: boolean;
  is_tiered_membership: boolean;
  comments_count: number;
  updated_at: string;
  deleted_at: string | null;
};

type AdminUsersProductsProductProps = {
  product: Product;
  isAffiliateUser?: boolean;
};

const AdminUsersProductsProduct = ({ product, isAffiliateUser = false }: AdminUsersProductsProductProps) => {
  const { url, props } = usePage();
  const compliance: Compliance = cast<Compliance>(props.compliance);
  const isCurrentUrl = url === Routes.admin_product_path(product.external_id);

  return (
    <article
      className="grid gap-4 rounded border border-border bg-background p-4"
      data-product-id={product.external_id}
    >
      <AdminProductHeader product={product} isCurrentUrl={isCurrentUrl} />
      <AdminProductDescription product={product} />
      <AdminProductDetails product={product} />
      <AdminProductInfo product={product} />
      <AdminProductActions product={product} />
      <AdminFlagForTosViolations product={product} compliance={compliance} />
      <AdminProductPurchases
        productExternalId={product.external_id}
        isAffiliateUser={isAffiliateUser}
        userExternalId={product.user.external_id}
      />
      <AdminProductComments product={product} />
      <AdminProductFooter product={product} />
    </article>
  );
};

export default AdminUsersProductsProduct;
