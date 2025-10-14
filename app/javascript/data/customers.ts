import { cast } from "ts-safe-cast";

import { ProductNativeType } from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { RecurrenceId } from "$app/utils/recurringPricing";
import { ResponseError, request } from "$app/utils/request";

import { PaginationProps } from "$app/components/Pagination";
import { Sort } from "$app/components/useSortingTableDriver";

export type SortKey = "created_at" | "price_cents";

export type Discount = ({ type: "fixed"; cents: number } | { type: "percent"; percents: number }) & {
  code: string | null;
};

export type License = { id: string; key: string; enabled: boolean };
export type Address = {
  full_name: string;
  street_address: string;
  city: string;
  state: string;
  zip_code: string;
  country: string;
};
export type Tracking = { shipped: false } | { shipped: true; url: string | null };
export type Option = { id: string; name: string };
export type ReviewResponse = { message: string };
export type Review = {
  rating: number;
  message: string | null;
  response: ReviewResponse | null;
  videos: ReviewVideo[];
};
export type ReviewVideo = {
  id: string;
  approval_status: "pending_review" | "approved" | "rejected";
  thumbnail_url: string | null;
  can_approve: boolean;
  can_reject: boolean;
};
export type Call = { id: string; call_url: string | null; start_time: string; end_time: string };
export type File = {
  id: string;
  name: string;
  size: number;
  extension: string;
  key: string;
};
export type Commission = {
  id: string;
  files: File[];
  status: "in_progress" | "completed" | "cancelled";
};

export type Customer = {
  id: string;
  email: string;
  giftee_email: string | null;
  is_existing_user: boolean;
  can_contact: boolean;
  name: string;
  is_bundle_purchase: boolean;
  product: {
    name: string;
    permalink: string;
    native_type: ProductNativeType;
  };
  physical: { sku: string; order_number: string } | null;
  shipping: { address: Address; tracking: Tracking; price: string } | null;
  created_at: string;
  price: {
    cents: number;
    cents_before_offer_code: number;
    cents_refundable: number;
    currency_type: CurrencyCode;
    recurrence: RecurrenceId | null;
    tip_cents: number | null;
  };
  quantity: number;
  discount: Discount | null;
  subscription: {
    id: string;
    status:
      | "alive"
      | "pending_failure"
      | "pending_cancellation"
      | "failed_payment"
      | "fixed_subscription_period_ended"
      | "cancelled"
      | null;
    is_installment_plan: boolean;
    remaining_charges: number | null;
  } | null;
  is_multiseat_license: boolean;
  upsell: string | null;
  referrer: string | null;
  is_additional_contribution: boolean;
  ppp: { country: string; discount: string } | null;
  is_preorder: boolean;
  affiliate: {
    email: string;
    amount: string;
    type: "GlobalAffiliate" | "DirectAffiliate" | "Collaborator";
  } | null;
  call: Call | null;
  commission: Commission | null;
  license: License | null;
  review: Review | null;
  custom_fields: ({ attribute: string } & ({ type: "text"; value: string } | { type: "file"; files: File[] }))[];
  transaction_url_for_seller: string | null;
  is_access_revoked: boolean | null;
  refunded: boolean;
  partially_refunded: boolean;
  chargedback: boolean;
  paypal_refund_expired: boolean;
  has_options: boolean;
  option: Option | null;
  utm_link: {
    title: string;
    utm_url: string;
    source: string;
    medium: string;
    campaign: string;
    term: string | null;
    content: string | null;
  } | null;
  download_count?: number | null;
};

export type Query = {
  page: number;
  query: string | null;
  sort: Sort<SortKey> | null;
  products: string[];
  variants: string[];
  excludedProducts: string[];
  excludedVariants: string[];
  minimumAmount: number | null;
  maximumAmount: number | null;
  createdAfter: Date | null;
  createdBefore: Date | null;
  country: string | null;
  activeCustomersOnly: boolean;
};

export const getPagedCustomers = ({
  page,
  query,
  sort,
  products,
  variants,
  excludedProducts,
  excludedVariants,
  minimumAmount,
  maximumAmount,
  createdAfter,
  createdBefore,
  country,
  activeCustomersOnly,
}: Query) => {
  const abort = new AbortController();
  const response = request({
    method: "GET",
    accept: "json",
    url: Routes.customers_paged_path({
      page,
      query,
      sort,
      products,
      variants,
      excluded_products: excludedProducts,
      excluded_variants: excludedVariants,
      minimum_amount_cents: minimumAmount,
      maximum_amount_cents: maximumAmount,
      created_after: createdAfter,
      created_before: createdBefore,
      country,
      active_customers_only: activeCustomersOnly,
    }),
    abortSignal: abort.signal,
  })
    .then((res) => res.json())
    .then((json) => cast<{ customers: Customer[]; pagination: PaginationProps | null; count: number }>(json));

  return {
    response,
    cancel: () => abort.abort(),
  };
};

export type MissedPost = {
  id: string;
  name: string;
  url: string;
  published_at: string;
};
export const getMissedPosts = (purchaseId: string, purchaseEmail: string) =>
  request({
    method: "GET",
    accept: "json",
    url: Routes.missed_posts_path(purchaseId, { purchase_email: purchaseEmail }),
  })
    .then((res) => {
      if (!res.ok) throw new ResponseError();
      return res.json();
    })
    .then((json) => cast<MissedPost[]>(json));

export type CustomerEmail = { id: string; name: string; state: string; state_at: string } & (
  | { type: "receipt"; url: string }
  | { type: "post" }
);
export const getCustomerEmails = (purchaseId: string) =>
  request({
    method: "GET",
    accept: "json",
    url: Routes.customer_emails_path(purchaseId),
  })
    .then((res) => {
      if (!res.ok) throw new ResponseError();
      return res.json();
    })
    .then((json) => cast<CustomerEmail[]>(json));

export const resendReceipt = (purchaseId: string) =>
  request({
    method: "POST",
    accept: "json",
    url: Routes.resend_receipt_purchase_path(purchaseId),
  }).then((response) => {
    if (!response.ok) throw new ResponseError();
  });

export const resendPost = async (purchaseId: string, postId: string) => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.send_for_purchase_path(postId, purchaseId),
  });
  if (!response.ok) throw new ResponseError(cast<{ message: string }>(await response.json()).message);
};

export const updatePurchase = (
  purchaseId: string,
  update: Partial<{ email: string; giftee_email: string; quantity: number } & Address>,
) =>
  request({
    method: "PUT",
    accept: "json",
    url: Routes.purchase_path(purchaseId, update),
  }).then((response) => {
    if (!response.ok) throw new ResponseError();
  });

export const changeCanContact = (purchaseId: string, canContact: boolean) =>
  request({
    method: "POST",
    accept: "json",
    url: Routes.change_can_contact_purchase_path(purchaseId, { can_contact: canContact }),
  }).then((response) => {
    if (!response.ok) throw new ResponseError();
  });

export const getProductPurchases = (purchaseId: string) =>
  request({
    method: "GET",
    accept: "json",
    url: Routes.product_purchases_path(purchaseId),
  })
    .then((res) => {
      if (!res.ok) throw new ResponseError();
      return res.json();
    })
    .then((json) => cast<Customer[]>(json));

export const updateLicense = (licenseId: string, enabled: boolean) =>
  request({ method: "PUT", accept: "json", url: Routes.license_path(licenseId, { enabled }) }).then((response) => {
    if (!response.ok) throw new ResponseError();
  });

export const markShipped = (purchaseId: string, trackingUrl: string) =>
  request({
    method: "POST",
    accept: "json",
    url: Routes.mark_as_shipped_path(purchaseId, { tracking_url: trackingUrl }),
  }).then((response) => {
    if (!response.ok) throw new ResponseError();
  });

export const cancelSubscription = (subscriptionId: string) =>
  request({
    method: "POST",
    accept: "json",
    url: Routes.unsubscribe_by_seller_subscription_path(subscriptionId),
  }).then((response) => {
    if (!response.ok) throw new ResponseError();
  });

export const resendPing = (purchaseId: string) =>
  request({
    method: "POST",
    accept: "json",
    url: Routes.purchase_pings_path(purchaseId),
  }).then((response) => {
    if (!response.ok) throw new ResponseError();
  });

export type Charge = {
  id: string;
  created_at: string;
  partially_refunded: boolean;
  refunded: boolean;
  amount_refundable: number;
  currency_type: CurrencyCode;
  transaction_url_for_seller: string | null;
  is_upgrade_purchase: boolean;
  chargedback: boolean;
  paypal_refund_expired: boolean;
};

export const getCharges = (purchaseId: string, purchaseEmail: string) =>
  request({
    method: "GET",
    accept: "json",
    url: Routes.customer_charges_path(purchaseId, { purchase_email: purchaseEmail }),
  })
    .then((response) => {
      if (!response.ok) throw new ResponseError();
      return response.json();
    })
    .then((json) => cast<Charge[]>(json));

export const refund = (purchaseId: string, amount: number) =>
  request({
    method: "PUT",
    accept: "json",
    url: Routes.refund_purchase_path(purchaseId, { amount }),
  })
    .then((response) => {
      if (!response.ok) throw new ResponseError();
      return response.json();
    })
    .then((json) => cast<{ success: true } | { success: false; message: string }>(json))
    .then((response) => {
      if (!response.success) throw new ResponseError(response.message);
    });

export const revokeAccess = (purchaseId: string) =>
  request({
    method: "PUT",
    accept: "json",
    url: Routes.revoke_access_purchase_path(purchaseId),
  }).then((response) => {
    if (!response.ok) throw new ResponseError();
  });

export const undoRevokeAccess = (purchaseId: string) =>
  request({
    method: "PUT",
    accept: "json",
    url: Routes.undo_revoke_access_purchase_path(purchaseId),
  }).then((response) => {
    if (!response.ok) throw new ResponseError();
  });

export const getOptions = (productPermalink: string) =>
  request({
    method: "GET",
    accept: "json",
    url: Routes.link_variants_path(productPermalink),
  })
    .then((response) => {
      if (!response.ok) throw new ResponseError();
      return response.json();
    })
    .then((json) => cast<Option[]>(json));

export const updateOption = (purchaseId: string, optionId: string, quantity: number) =>
  request({
    method: "PUT",
    accept: "json",
    url: Routes.purchase_variant_path(purchaseId, optionId, { quantity }),
  }).then((response) => {
    if (!response.ok) throw new ResponseError();
  });

export const updateReviewResponse = (purchaseId: string, message: string) =>
  request({
    method: "PUT",
    accept: "json",
    url: Routes.product_review_response_path(purchaseId),
    data: { message },
  }).then((response) => {
    if (!response.ok) throw new ResponseError();
  });

export const deleteReviewResponse = (purchaseId: string) =>
  request({
    method: "DELETE",
    accept: "json",
    url: Routes.product_review_response_path(purchaseId),
  }).then((response) => {
    if (!response.ok) throw new ResponseError();
  });

export const updateCallUrl = (callId: string, callUrl: string) =>
  request({
    method: "PUT",
    accept: "json",
    url: Routes.call_path(callId),
    data: { call_url: callUrl },
  }).then((response) => {
    if (!response.ok) throw new ResponseError();
  });

export const updateCommission = (commissionId: string, fileSignedIds: string[]) =>
  request({
    method: "PUT",
    accept: "json",
    url: Routes.commission_path(commissionId),
    data: { file_signed_ids: fileSignedIds },
  }).then((response) => {
    if (!response.ok) throw new ResponseError();
  });

export const completeCommission = async (commissionId: string) => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.complete_commission_path(commissionId),
  });

  if (!response.ok) {
    throw new ResponseError(cast<{ errors: string[] }>(await response.json()).errors[0]);
  }
};

export const approveReviewVideo = async (videoId: string) => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.internal_product_review_video_approvals_url(videoId),
  });

  if (!response.ok) {
    throw new ResponseError();
  }
};

export const rejectReviewVideo = async (videoId: string) => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.internal_product_review_video_rejections_url(videoId),
  });

  if (!response.ok) {
    throw new ResponseError();
  }
};
