import React from "react";

import Loading from "$app/components/Admin/Loading";
import { type ActiveIntegration } from "$app/components/Admin/Products/Product";
import { BooleanIcon } from "$app/components/Icons";

export type InfoProps = {
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
  user_all_adult_products: boolean;
  has_adult_keywords: boolean;
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

const AdminProductInfoContent = ({ info, isLoading }: { info: InfoProps; isLoading: boolean }) => {
  if (isLoading) return <Loading />;

  const hasCircleIntegration = info.active_integrations.some((integration) => integration.type === "CircleIntegration");
  const hasDiscordIntegration = info.active_integrations.some(
    (integration) => integration.type === "DiscordIntegration",
  );

  return (
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

      <dt>Is Adult (on user)</dt>
      <dd>
        <BooleanIcon value={info.user_all_adult_products} />
      </dd>

      <dt>Has adult keywords</dt>
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
  );
};

export default AdminProductInfoContent;
