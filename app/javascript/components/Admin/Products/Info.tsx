import React from "react";
import { cast } from "ts-safe-cast";

import { useLazyFetch } from "$app/hooks/useLazyFetch";

import { BooleanIcon } from "$app/components/Admin/Icons";
import { ActiveIntegration, type Product } from "$app/components/Admin/Products/Product";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { useIsIntersecting } from "$app/components/useIsIntersecting";

type InfoProps = {
  purchase_type: string;
  external_id: string;
  alive: boolean;
  recommendable: boolean;
  staff_picked: boolean;
  is_in_preorder_state: boolean;
  has_stampable_pdfs: boolean;
  streamable: boolean;
  is_physical: boolean;
  is_licensed: boolean;
  is_adult: boolean;
  has_adult_keywords: boolean;
  user: {
    all_adult_products: boolean;
  };
  taxonomy?: {
    ancestry_path: string[];
  } | null;
  tags: {
    humanized_name: string;
  }[];
  active_integrations: ActiveIntegration[];
  type: string;
  formatted_rental_price_cents: string;
};

type Props = {
  product: Product;
};

const AdminProductInfo = ({ product }: Props) => {
  const {
    data: info,
    isLoading,
    fetchData,
  } = useLazyFetch<InfoProps | null>(null, {
    fetchUnlessLoaded: false,
    url: Routes.admin_product_info_path(product.id, { format: "json" }),
    responseParser: (data) => cast<{ info: InfoProps }>(data).info,
  });

  const elementRef = useIsIntersecting<HTMLDivElement>((isIntersecting) => {
    if (!isIntersecting || info) return;
    void fetchData();
  });

  const hasCircleIntegration =
    info?.active_integrations.some((integration) => integration.type === "CircleIntegration") ?? false;
  const hasDiscordIntegration =
    info?.active_integrations.some((integration) => integration.type === "DiscordIntegration") ?? false;

  return (
    <div ref={elementRef} className="border-t border-border pt-4">
      <h3 className="mb-4">Info</h3>
      {isLoading || !info ? (
        <LoadingSpinner />
      ) : (
        <dl>
          <dt>Type</dt>
          <dd>{info.type}</dd>

          <dt>External ID</dt>
          <dd>{info.external_id}</dd>

          <dt>Published</dt>
          <dd>
            <BooleanIcon value={info.alive} />
          </dd>

          <dt>Listed on Discover</dt>
          <dd>
            <BooleanIcon value={info.recommendable} />
          </dd>

          <dt>Staff-picked</dt>
          <dd>
            <BooleanIcon value={info.staff_picked} />
          </dd>

          <dt>Preorder</dt>
          <dd>
            <BooleanIcon value={info.is_in_preorder_state} />
          </dd>

          {info.purchase_type !== "buy_only" && (
            <>
              <dt>Purchase type</dt>
              <dd>{info.purchase_type}</dd>

              <dt>Rental price</dt>
              <dd>{info.formatted_rental_price_cents}</dd>
            </>
          )}

          <dt>Has stamped PDFs</dt>
          <dd>
            <BooleanIcon value={info.has_stampable_pdfs} />
          </dd>

          <dt>Streaming</dt>
          <dd>
            <BooleanIcon value={info.streamable} />
          </dd>

          <dt>Physical</dt>
          <dd>
            <BooleanIcon value={info.is_physical} />
          </dd>

          <dt>Licensed</dt>
          <dd>
            <BooleanIcon value={info.is_licensed} />
          </dd>

          <dt>Is Adult (on product)</dt>
          <dd>
            <BooleanIcon value={info.is_adult} />
          </dd>

          <dt>Is Adult (on user profile)</dt>
          <dd>
            <BooleanIcon value={info.user.all_adult_products} />
          </dd>

          <dt>Is Adult (keywords)</dt>
          <dd>
            <BooleanIcon value={info.has_adult_keywords} />
          </dd>

          <dt>Category</dt>
          <dd>{info.taxonomy?.ancestry_path.join(" > ")}</dd>

          <dt>Tags</dt>
          <dd>{info.tags.map((tag) => tag.humanized_name).join(", ")}</dd>

          <dt>Circle Community</dt>
          <dd>
            <BooleanIcon value={hasCircleIntegration} />
          </dd>

          <dt>Discord Channel</dt>
          <dd>
            <BooleanIcon value={hasDiscordIntegration} />
          </dd>
        </dl>
      )}
    </div>
  );
};

export default AdminProductInfo;
