import { cast } from "ts-safe-cast";

import { ConfirmedPurchaseResponse } from "$app/data/purchase";
import { trackUserProductAction } from "$app/data/user_action_event";
import { AnalyticsData } from "$app/parsers/product";
import { getIsSingleUnitCurrency } from "$app/utils/currency";
import { assertResponseError } from "$app/utils/request";
import { startTrackingForSeller, trackProductEvent } from "$app/utils/user_analytics";

import { addThirdPartyAnalytics } from "$app/components/useAddThirdPartyAnalytics";

declare global {
  interface Window {
    tracking?: {
      ctaClick: () => void;
      productPurchase: (result: ConfirmedPurchaseResponse) => void;
    };
  }
}

const {
  enabled,
  seller_id,
  analytics,
  has_product_third_party_analytics,
  has_receipt_third_party_analytics,
  third_party_analytics_domain,
  permalink,
  name,
} = cast<{
  enabled: boolean;
  seller_id: string;
  analytics: AnalyticsData;
  has_product_third_party_analytics: boolean;
  has_receipt_third_party_analytics: boolean;
  third_party_analytics_domain: string;
  permalink: string;
  name: string;
}>(JSON.parse(document.querySelector("meta[name=props]")?.getAttribute("content") ?? ""));

if (enabled) {
  window.tracking = {
    ctaClick: () => {
      trackProductEvent(seller_id, {
        permalink,
        action: "iwantthis",
        product_name: name,
      });
      trackUserProductAction({
        name: "i_want_this",
        permalink,
        fromOverlay: false,
        wasRecommended: true,
      }).catch(assertResponseError);
    },
    productPurchase: (result) => {
      trackProductEvent(seller_id, {
        action: "purchased",
        seller_id: result.seller_id,
        permalink: result.permalink,
        purchase_external_id: result.id,
        currency: result.currency_type.toUpperCase(),
        product_name: result.name,
        value: result.non_formatted_price,
        valueIsSingleUnit: getIsSingleUnitCurrency(cast(result.currency_type)),
        quantity: result.quantity,
        tax: result.non_formatted_seller_tax_amount,
      });
      if (has_receipt_third_party_analytics)
        addThirdPartyAnalytics({
          domain: third_party_analytics_domain,
          permalink: result.permalink,
          location: "receipt",
          purchaseId: result.id,
        });
    },
  };

  startTrackingForSeller(seller_id, analytics);
  trackProductEvent(seller_id, {
    permalink,
    action: "viewed",
    product_name: name,
  });
  if (has_product_third_party_analytics)
    addThirdPartyAnalytics({ domain: third_party_analytics_domain, permalink, location: "product" });
} else {
  window.tracking = {
    ctaClick: () => {},
    productPurchase: () => {},
  };
}
