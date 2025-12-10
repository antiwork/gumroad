import { Link } from "@inertiajs/react";
import React from "react";

import DateTimeWithRelativeTooltip from "$app/components/Admin/DateTimeWithRelativeTooltip";
import { type Product } from "$app/components/Admin/Products/Product";
import AdminProductStats from "$app/components/Admin/Products/Stats";
import { Icon } from "$app/components/Icons";

import coverPlaceholder from "$assets/images/cover_placeholder.png";

type Props = {
  product: Product;
  isCurrentUrl: boolean;
};

const AdminUsersProductsHeader = ({ product, isCurrentUrl }: Props) => (
  <div className="flex flex-col gap-4">
    <div className="flex items-center gap-4">
      {product.preview_url ? (
        <a href={product.preview_url} target="_blank" rel="noreferrer noopener">
          <img src={product.preview_url} alt="Preview image" style={{ width: "var(--form-element-height)" }} />
        </a>
      ) : (
        <img src={coverPlaceholder} alt="Cover placeholder" style={{ width: "var(--form-element-height)" }} />
      )}

      <div className="grid gap-2">
        <h2 className="flex items-center gap-2">
          {product.price_formatted}
          <span>&bull;</span>
          {isCurrentUrl ? (
            product.name
          ) : (
            <Link href={Routes.admin_product_path(product.external_id)}>{product.name}</Link>
          )}
          <Link href={product.long_url} target="_blank" rel="noreferrer noopener">
            <Icon name="arrow-up-right-square" />
          </Link>
        </h2>

        <div>
          <ul className="inline">
            <li>
              <DateTimeWithRelativeTooltip date={product.created_at} utc />
            </li>
            <li>
              <Link href={Routes.admin_user_path(product.user.external_id)}>{product.user.name}</Link>
            </li>
            <AdminProductStats product_external_id={product.external_id} />
          </ul>
        </div>
      </div>
    </div>

    <div className="flex flex-wrap gap-2">
      <a
        href={Routes.edit_link_path(product.unique_permalink)}
        className="button small"
        target="_blank"
        rel="noreferrer"
      >
        Edit
      </a>
      {product.admins_can_generate_url_redirects ? (
        <a
          href={Routes.generate_url_redirect_admin_product_path(product.external_id)}
          className="button small"
          target="_blank"
          rel="noreferrer noopener"
        >
          View download page
        </a>
      ) : null}
      {product.alive_product_files.map((file) => (
        <a
          key={file.external_id}
          href={Routes.admin_access_product_file_admin_product_path(product.unique_permalink, file.external_id)}
          className="button small"
          target="_blank"
          rel="noreferrer noopener"
        >
          {file.s3_filename || file.external_id}
        </a>
      ))}
    </div>
  </div>
);

export default AdminUsersProductsHeader;
