import React from "react";

import { NoIcon, YesIcon } from "$app/components/Admin/Icons";
import Loading from "$app/components/Admin/Loading";
import { type ActiveIntegration } from "$app/components/Admin/Products/Product";

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

const AdminProductInfoContent = ({ info, isLoading }: { info: InfoProps | null; isLoading: boolean }) => {
  if (isLoading || !info) return <Loading />;

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
      <dd>{info.alive ? <YesIcon /> : <NoIcon />}</dd>

      <dt>Listed on Discover</dt>
      <dd>{info.recommendable ? <YesIcon /> : <NoIcon />}</dd>

      <dt>Staff-picked</dt>
      <dd>{info.staff_picked ? <YesIcon /> : <NoIcon />}</dd>

      <dt>Preorder</dt>
      <dd>{info.is_in_preorder_state ? <YesIcon /> : <NoIcon />}</dd>

      {info.purchase_type !== "buy_only" && (
        <>
          <dt>Purchase type</dt>
          <dd>{info.purchase_type}</dd>

          <dt>Rental price</dt>
          <dd>{info.formatted_rental_price_cents}</dd>
        </>
      )}

      <dt>Has stamped PDFs</dt>
      <dd>{info.has_stampable_pdfs ? <YesIcon /> : <NoIcon />}</dd>

      <dt>Streaming</dt>
      <dd>{info.streamable ? <YesIcon /> : <NoIcon />}</dd>

      <dt>Physical</dt>
      <dd>{info.is_physical ? <YesIcon /> : <NoIcon />}</dd>

      <dt>Licensed</dt>
      <dd>{info.is_licensed ? <YesIcon /> : <NoIcon />}</dd>

      <dt>Is Adult (on product)</dt>
      <dd>{info.is_adult ? <YesIcon /> : <NoIcon />}</dd>

      <dt>Is Adult (on user)</dt>
      <dd>{info.user.all_adult_products ? <YesIcon /> : <NoIcon />}</dd>

      <dt>Has adult keywords</dt>
      <dd>{info.has_adult_keywords ? <YesIcon /> : <NoIcon />}</dd>

      <dt>Category</dt>
      <dd>{info.taxonomy?.ancestry_path.join(" > ")}</dd>

      <dt>Tags</dt>
      <dd>{info.tags.map((tag) => tag.humanized_name).join(", ")}</dd>

      <dt>Circle Community</dt>
      <dd>{hasCircleIntegration ? <YesIcon /> : <NoIcon />}</dd>

      <dt>Discord Channel</dt>
      <dd>{hasDiscordIntegration ? <YesIcon /> : <NoIcon />}</dd>
    </dl>
  );
};

export default AdminProductInfoContent;
