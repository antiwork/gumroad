import * as React from "react";
import { createCast } from "ts-safe-cast";

import { request, assertResponseError, ResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { showAlert } from "$app/components/server-components/Alert";

const AdminProductStats = ({ product_id }: { product_id: number }) => {
  const [viewsCountHtml, setViewsCountHtml] = React.useState<string>("");
  const [salesStatsHtml, setSalesStatsHtml] = React.useState<string>("");

  React.useEffect(() => {
    const loadProductAnalyticsStats = async () => {
      try {
        const viewsCountResponse = await request({
          method: "GET",
          url: Routes.views_count_admin_product_path(product_id),
          accept: "html",
        });
        if (!viewsCountResponse.ok) throw new ResponseError("Server returned error response");
        const viewsCount = await viewsCountResponse.text();
        setViewsCountHtml(viewsCount);
      } catch (e) {
        assertResponseError(e);
        showAlert(e.message, "error");
      }

      try {
        const salesStatsResponse = await request({
          method: "GET",
          url: Routes.sales_stats_admin_product_path(product_id),
          accept: "html",
        });
        if (!salesStatsResponse.ok) throw new ResponseError("Server returned error response");
        const salesStats = await salesStatsResponse.text();
        setSalesStatsHtml(salesStats);
      } catch (e) {
        assertResponseError(e);
        showAlert(e.message, "error");
      }
    };

    void loadProductAnalyticsStats();
  }, []);

  return (
    <>
      {viewsCountHtml ? (
        <ul className="inline">
          <li dangerouslySetInnerHTML={{ __html: viewsCountHtml }} />
        </ul>
      ) : (
        <div role="progressbar" style={{ width: "0.75em" }} />
      )}
      {salesStatsHtml ? (
        <ul className="inline" dangerouslySetInnerHTML={{ __html: salesStatsHtml }} />
      ) : (
        <div role="progressbar" style={{ width: "0.75em" }} />
      )}
    </>
  );
};

export default register({ component: AdminProductStats, propParser: createCast() });
