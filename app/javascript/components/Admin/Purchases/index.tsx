import { Link } from "@inertiajs/react";
import React from "react";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import AdminActionButton from "$app/components/Admin/ActionButton";
import AdminCommentableComments from "$app/components/Admin/Commentable";
import DateTimeWithRelativeTooltip from "$app/components/Admin/DateTimeWithRelativeTooltip";
import { Form } from "$app/components/Admin/Form";
import { NoIcon, BooleanIcon } from "$app/components/Admin/Icons";
import AdminResendReceiptForm from "$app/components/Admin/Purchases/ResendReceiptForm";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Icon } from "$app/components/Icons";
import { showAlert } from "$app/components/server-components/Alert";

import { type RefundPolicy, RefundPolicyTitle } from "./RefundPolicy";
import { type PurchaseStatesInfo, PurchaseStates } from "./States";

type UrlRedirect = {
  download_page_url: string;
  uses: number;
};

type Gift = {
  is_sender_purchase: boolean;
  other_purchase_id: number;
  other_email: string;
  note: string | null;
};

export type Purchase = PurchaseStatesInfo & {
  id: number;
  external_id: string;
  seller: {
    support_email: string | null;
    email: string;
  };
  merchant_account: {
    id: number;
    charge_processor_id: string;
    holder_of_funds: string;
  } | null;
  fee_cents: number;
  tip: number | null;
  formatted_seller_tax_amount: string | null;
  gumroad_tax_cents: number;
  formatted_display_price: string;
  formatted_gumroad_tax_amount: string | null;
  formatted_shipping_amount: string | null;
  formatted_affiliate_credit_amount: string | null;
  gumroad_responsible_for_tax: boolean;
  product: {
    id: number;
    name: string;
    long_url: string;
  };
  variants_list: string;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
  email: string;
  purchase_state: string;
  formatted_total_transaction_amount: string;
  charge_processor_id: string | null;
  stripe_transaction: { id: string; search_url: string | null } | null;
  external_id_numeric: number;
  quantity: number;
  refunds: {
    user: { id: number; name: string | null } | null;
    status: string;
    created_at: string;
  }[];
  card: {
    type: string;
    visual: string;
    country: string | null;
    fingerprint_search_url: string | null;
  } | null;
  ip_address: string | null;
  ip_country: string | null;
  is_preorder_authorization: boolean;
  subscription: {
    id: number;
    external_id: string;
    cancelled_at: string | null;
    cancelled_by_buyer: boolean | null;
    ended_at: string | null;
    failed_at: string | null;
  } | null;
  email_info: string | null;
  is_bundle_purchase: boolean;
  product_purchases: {
    product: { name: string };
    url_redirect: UrlRedirect | null;
  }[];
  url_redirect: UrlRedirect | null;
  offer_code: { code: string; displayed_amount_off: string } | null;
  street_address: string | null;
  full_name: string | null;
  city: string | null;
  state: string | null;
  zip_code: string | null;
  country: string | null;
  custom_fields: { name: string; value: string | boolean }[];
  license: { serial: string } | null;
  affiliate_email: string | null;
  refund_policy:
    | (RefundPolicy & {
        fine_print: string | null;
        max_refund_period_in_days: number | null;
      })
    | null;
  can_contact: boolean;
  gift: Gift | null;
  successful: boolean;
  can_force_update: boolean;
  failed: boolean;
  stripe_fingerprint: string | null;
  is_free_trial_purchase: boolean;
  buyer_blocked: boolean;
  is_deleted_by_buyer: boolean;
  comments_count: number;
};

const Header = ({ purchase }: { purchase: Purchase }) => (
  <div className="grid gap-2">
    <h2>
      <Link href={Routes.admin_purchase_path(purchase.id)}>{purchase.formatted_display_price}</Link>
      {purchase.gumroad_responsible_for_tax ? ` + ${purchase.formatted_gumroad_tax_amount} VAT` : null} for{" "}
      <Link href={Routes.admin_product_path(purchase.product.id)} title={purchase.product.id.toString()}>
        {purchase.product.name}
      </Link>{" "}
      {purchase.variants_list}{" "}
      <Link href={purchase.product.long_url}>
        <Icon name="arrow-up-right-square" />
      </Link>
    </h2>
    <ul className="inline">
      <li>
        <DateTimeWithRelativeTooltip date={purchase.created_at} />
      </li>
      <li>
        <Link href={Routes.admin_search_purchases_path({ query: purchase.email })}>{purchase.email}</Link>
      </li>
    </ul>
  </div>
);

const Info = ({ purchase }: { purchase: Purchase }) => (
  <div className="flex flex-col gap-4">
    <h3>Info</h3>
    <dl>
      {purchase.seller.support_email ? (
        <>
          <dt>Seller support email</dt>
          <dd>
            <CopyToClipboard text={purchase.seller.support_email}>
              <Icon name="outline-duplicate" />
            </CopyToClipboard>
          </dd>
        </>
      ) : null}

      <dt>Seller email</dt>
      <dd>
        {purchase.seller.email}{" "}
        <CopyToClipboard text={purchase.seller.email}>
          <Icon name="outline-duplicate" />
        </CopyToClipboard>
      </dd>

      {purchase.merchant_account ? (
        <>
          <dt>Merchant account</dt>
          <dd>
            <Link href={Routes.admin_merchant_account_path(purchase.merchant_account.id)}>
              {purchase.merchant_account.id} – {purchase.merchant_account.charge_processor_id}
            </Link>
          </dd>
          <dt>Funds held by</dt>
          <dd>{purchase.merchant_account.holder_of_funds}</dd>
        </>
      ) : null}

      <dt>Fee</dt>
      <dd>
        {formatPriceCentsWithCurrencySymbol("usd", purchase.fee_cents, {
          symbolFormat: "long",
          noCentsIfWhole: true,
        })}
      </dd>

      {purchase.tip ? (
        <>
          <dt>Tip</dt>
          <dd>
            {formatPriceCentsWithCurrencySymbol("usd", purchase.tip, {
              symbolFormat: "long",
              noCentsIfWhole: true,
            })}
          </dd>
        </>
      ) : null}

      {purchase.formatted_seller_tax_amount ? (
        <>
          <dt>Seller Tax</dt>
          <dd>{purchase.formatted_seller_tax_amount}</dd>
        </>
      ) : null}

      {purchase.formatted_gumroad_tax_amount ? (
        <>
          <dt>Gumroad Collected Tax</dt>
          <dd>{purchase.formatted_gumroad_tax_amount}</dd>
        </>
      ) : null}

      {purchase.formatted_shipping_amount ? (
        <>
          <dt>Shipping Cost</dt>
          <dd>{purchase.formatted_shipping_amount}</dd>
        </>
      ) : null}

      {purchase.formatted_affiliate_credit_amount ? (
        <>
          <dt>Affiliate</dt>
          <dd>{purchase.formatted_affiliate_credit_amount}</dd>
        </>
      ) : null}

      <dt>Transaction Total</dt>
      <dd>{purchase.formatted_total_transaction_amount}</dd>

      <dt>{purchase.charge_processor_id} transaction ID</dt>
      <dd>
        {purchase.stripe_transaction ? (
          purchase.stripe_transaction.search_url ? (
            <Link href={purchase.stripe_transaction.search_url} target="_blank">
              {purchase.stripe_transaction.id}
            </Link>
          ) : (
            purchase.stripe_transaction.id
          )
        ) : null}
        {" | "}
        <Link href={Routes.admin_purchase_path(purchase.id)}>{purchase.id}</Link>
      </dd>

      <dt>Order number</dt>
      <dd>{purchase.external_id_numeric}</dd>

      {purchase.quantity > 1 ? (
        <>
          <dt>Quantity</dt>
          <dd>{purchase.quantity}</dd>
        </>
      ) : null}

      <dt>Status</dt>
      <dd>
        <PurchaseStates purchase={purchase} />
      </dd>

      {purchase.refunds.length > 0 ? (
        <>
          <dt>Refunds</dt>
          <dd>
            <ul>
              {purchase.refunds.map((refund) => (
                <>
                  <li>
                    Refunder:
                    {refund.user ? (
                      <Link href={Routes.admin_user_path(refund.user.id)}>
                        {refund.user.name || `User ${refund.user.id}`}
                      </Link>
                    ) : (
                      "(unknown)"
                    )}
                  </li>
                  <li>
                    Refund Status:
                    {refund.status}
                  </li>
                  <li>
                    Date of refund:
                    <DateTimeWithRelativeTooltip date={refund.created_at} />
                  </li>
                </>
              ))}
            </ul>
          </dd>
        </>
      ) : null}

      {purchase.card ? (
        <>
          <dt>Card</dt>
          <dd>
            <Link href={Routes.admin_search_purchases_path({ query: purchase.stripe_fingerprint })}>
              {purchase.card.type}
              *#{purchase.card.visual} {purchase.card.country ? `(${purchase.card.country})` : null}
            </Link>
            {purchase.card.fingerprint_search_url ? (
              <>
                {" | "}
                <Link href={purchase.card.fingerprint_search_url} target="_blank">
                  {purchase.stripe_fingerprint}
                </Link>
              </>
            ) : null}
          </dd>

          <dt>IP Address</dt>
          <dd>
            <Link href={Routes.admin_search_purchases_path({ query: purchase.ip_address })}>{purchase.ip_address}</Link>
          </dd>

          <dt>IP Country</dt>
          <dd>{purchase.ip_country}</dd>
        </>
      ) : null}

      {purchase.email_info ? (
        <>
          <dt>{purchase.is_preorder_authorization ? "Pre-order Receipt" : "Receipt"}</dt>
          <dd>{purchase.email_info}</dd>
        </>
      ) : null}

      {purchase.is_bundle_purchase ? (
        purchase.product_purchases.map((product_purchase) =>
          product_purchase.url_redirect ? (
            <PurchaseUrlRedirect
              key={product_purchase.product.name}
              url_redirect={product_purchase.url_redirect}
              label={product_purchase.product.name}
            />
          ) : null,
        )
      ) : purchase.url_redirect ? (
        <PurchaseUrlRedirect url_redirect={purchase.url_redirect} label="URL redirect" />
      ) : null}

      {purchase.subscription ? (
        <>
          <dt>Manage Membership URL</dt>
          <dd>
            <Link href={Routes.manage_subscription_url(purchase.subscription.external_id)} target="_blank">
              {Routes.manage_subscription_url(purchase.subscription.external_id)}
            </Link>
          </dd>
        </>
      ) : null}

      {purchase.offer_code && !purchase.gift?.is_sender_purchase ? (
        <>
          <dt>Discount code</dt>
          <dd>
            {purchase.offer_code.code} for {purchase.offer_code.displayed_amount_off} off
          </dd>
        </>
      ) : null}

      {purchase.street_address ? (
        <>
          <dt>Shipping</dt>
          <dd>
            {purchase.full_name} {purchase.street_address} {purchase.city}, {purchase.state} {purchase.zip_code}{" "}
            {purchase.country}
          </dd>
        </>
      ) : null}

      {purchase.custom_fields.map((field, index) => (
        <React.Fragment key={index}>
          <dt>{field.name}</dt>
          <dd>{field.value.toString()} (custom field)</dd>
        </React.Fragment>
      ))}

      {purchase.purchase_state === "preorder_authorization_successful" ? (
        <AdminActionButton
          label="Cancel Pre-order"
          url={Routes.cancel_preorder_by_seller_path(purchase.external_id)}
          loading="Canceling..."
          done="Cancelled!"
          confirm_message="Are you sure you want to cancel this preorder?"
          success_message="Cancelled!"
        />
      ) : null}

      {purchase.subscription ? (
        <>
          <dt>Cancelled</dt>
          <dd>
            <BooleanIcon value={!!purchase.subscription.cancelled_at} />
            {purchase.subscription.cancelled_at
              ? ` (on ${purchase.subscription.cancelled_at} by ${purchase.subscription.cancelled_by_buyer ? "buyer" : "seller"})`
              : null}
          </dd>

          <dt>Ended</dt>
          <dd>
            <BooleanIcon value={!!purchase.subscription.ended_at} />
            {purchase.subscription.ended_at ? ` (on ${purchase.subscription.ended_at})` : null}
          </dd>

          <dt>Failed</dt>
          <dd>
            <BooleanIcon value={!!purchase.subscription.failed_at} />
            {purchase.subscription.failed_at ? ` (on ${purchase.subscription.failed_at})` : null}
          </dd>
        </>
      ) : null}

      {purchase.license ? (
        <>
          <dt>License</dt>
          <dd>{purchase.license.serial}</dd>
        </>
      ) : null}

      {purchase.affiliate_email ? (
        <>
          <dt>Affiliate</dt>
          <dd>
            <Link href={Routes.admin_search_users_path({ query: purchase.affiliate_email })}>
              {purchase.affiliate_email}
            </Link>
          </dd>
        </>
      ) : null}

      {purchase.refund_policy ? (
        <>
          <dt>Refund Policy</dt>
          <dd>
            <strong>
              <RefundPolicyTitle refundPolicy={purchase.refund_policy} />
              {purchase.refund_policy.fine_print ? (
                <>
                  <br />
                  <div className="whitespace-pre-wrap">{purchase.refund_policy.fine_print}</div>
                </>
              ) : null}
              {purchase.refund_policy.max_refund_period_in_days ? (
                <>
                  <br />
                  Max refund period: {purchase.refund_policy.max_refund_period_in_days} days
                </>
              ) : null}
            </strong>
          </dd>
        </>
      ) : null}

      <dt>Can email</dt>
      <dd aria-label="Can email">
        <BooleanIcon value={purchase.can_contact} />
      </dd>
    </dl>
  </div>
);

const GiftInfo = ({ purchaseId, gift }: { purchaseId: number; gift: Gift }) =>
  gift.is_sender_purchase ? (
    <>
      <details>
        <summary>
          <h3>Gift Sender Info</h3>
        </summary>
        <dl>
          <dt>For</dt>
          <dd>{gift.other_email}</dd>

          <dt>Note</dt>
          <dd>{gift.note}</dd>

          <dt>Receiver purchase id</dt>
          <dd>
            <Link href={Routes.admin_purchase_path(gift.other_purchase_id)}>{gift.other_purchase_id}</Link>
          </dd>
        </dl>
      </details>

      <hr />
      <details>
        <summary>
          <h3>Edit giftee email</h3>
        </summary>
        <Form
          url={Routes.update_giftee_email_admin_purchase_path(purchaseId)}
          method="POST"
          onSuccess={() => showAlert("Successfully updated the giftee email.", "success")}
        >
          {(isLoading) => (
            <div className="flex gap-2">
              <input type="text" className="flex-1" name="giftee_email" placeholder="Enter new giftee email" required />
              <button type="submit" className="button" disabled={isLoading}>
                {isLoading ? "Updating..." : "Update"}
              </button>
            </div>
          )}
        </Form>
      </details>
    </>
  ) : (
    <details>
      <summary>
        <h3>Gift Receiver Info</h3>
      </summary>
      <dl>
        <dt>From</dt>
        <dd>{gift.other_email}</dd>

        <dt>Note</dt>
        <dd>{gift.note}</dd>

        <dt>Sender purchase id</dt>
        <dd>
          <Link href={Routes.admin_purchase_path(gift.other_purchase_id)}>{gift.other_purchase_id}</Link>
        </dd>
      </dl>
    </details>
  );

const ActionButtons = ({ purchase }: { purchase: Purchase }) => (
  <div className="flex flex-wrap gap-2">
    {purchase.can_force_update || purchase.failed ? (
      <AdminActionButton
        label="Sync with Stripe/PayPal"
        url={Routes.sync_status_with_charge_processor_admin_purchase_path(purchase)}
        loading="syncing..."
        done="synced!"
        confirm_message="Are you sure you want to sync this purchase's state with Stripe/PayPal?"
        success_message="synced!"
      />
    ) : null}
    {purchase.successful && !purchase.stripe_refunded ? (
      <>
        <AdminActionButton
          label="Refund"
          url={Routes.refund_admin_purchase_path(purchase)}
          loading="Refunding..."
          done="Refunded!"
          confirm_message="Are you sure you want to refund this purchase?"
          success_message="Refunded!"
        />
        <AdminActionButton
          label="Refund for Fraud"
          url={Routes.refund_for_fraud_admin_purchase_path(purchase)}
          loading="Refunding..."
          done="Refunded!"
          confirm_message="Are you sure you want to refund this purchase for fraud?"
          success_message="Refunded!"
        />
        <AdminActionButton
          label="Refund taxes only"
          url={Routes.refund_taxes_only_admin_purchase_path(purchase)}
          loading="Refunding taxes..."
          done="Taxes refunded!"
          confirm_message="Are you sure you want to refund only the taxes for this purchase?"
          success_message="Taxes refunded!"
        />
        <AdminActionButton
          label="Refund Card for Fraud"
          url={Routes.refund_admin_cards_path({ stripe_fingerprint: purchase.stripe_fingerprint })}
          loading="Refunding..."
          done="Refunding purchases!"
          confirm_message="Are you sure you want to Mass-refund for fraud all purchases associated with this purchase's card?"
          success_message="Refunding purchases!"
        />
      </>
    ) : null}
    {purchase.subscription &&
    !purchase.subscription.cancelled_at &&
    !purchase.subscription.ended_at &&
    !purchase.subscription.failed_at ? (
      <>
        <AdminActionButton
          label="Cancel subscription for buyer"
          url={Routes.cancel_subscription_admin_purchase_path(purchase, { by_seller: false })}
          loading="Canceling..."
          done="Canceled!"
          confirm_message="Are you sure you want to cancel this subscription on behalf of the buyer?"
          success_message="Canceled!"
        />
        <AdminActionButton
          label="Cancel subscription for seller"
          url={Routes.cancel_subscription_admin_purchase_path(purchase, { by_seller: true })}
          loading="Canceling..."
          done="Canceled!"
          confirm_message="Are you sure you want to cancel this subscription on behalf of the seller?"
          success_message="Canceled!"
        />
      </>
    ) : null}
    {purchase.buyer_blocked ? (
      <AdminActionButton
        label="Unblock buyer"
        url={Routes.unblock_buyer_admin_purchase_path(purchase)}
        loading="Unblocking buyer..."
        done="Buyer unblocked!"
        success_message="Buyer unblocked!"
      />
    ) : (
      <AdminActionButton
        label="Block buyer"
        url={Routes.block_buyer_admin_purchase_path(purchase)}
        loading="Blocking buyer..."
        done="Buyer blocked!"
        confirm_message="This will fully block this buyer's emails, GUID, and IP addresses. Proceed?"
        success_message="Buyer blocked!"
      />
    )}
    {purchase.is_deleted_by_buyer ? (
      <AdminActionButton
        label="Undelete"
        url={Routes.undelete_admin_purchase_path(purchase)}
        loading="Undeleting..."
        done="Undeleted!"
        confirm_message="Are you sure you want to undelete this purchase?"
        success_message="Undeleted!"
      />
    ) : null}
    {purchase.successful ? (
      <Link href={Routes.receipt_purchase_path(purchase.external_id)} target="_blank" className="button small">
        Go to Receipt
      </Link>
    ) : null}
  </div>
);

const PurchaseUrlRedirect = ({
  url_redirect,
  label = "URL redirect",
}: {
  url_redirect: UrlRedirect;
  label?: string;
}) => (
  <>
    <dt>{label}</dt>
    <dd>
      <Link href={url_redirect.download_page_url} target="_blank">
        {url_redirect.download_page_url}
      </Link>{" "}
      ({url_redirect.uses} uses)
    </dd>
  </>
);

const AdminPurchase = ({ purchase }: { purchase: Purchase }) => (
  <div className="grid gap-4 rounded border border-border bg-background p-4">
    <Header purchase={purchase} />
    <hr />
    <Info purchase={purchase} />
    {purchase.gift ? (
      <>
        <hr />
        <GiftInfo purchaseId={purchase.id} gift={purchase.gift} />
      </>
    ) : null}
    {purchase.successful ||
    purchase.purchase_state === "preorder_authorization_successful" ||
    purchase.is_free_trial_purchase ? (
      <>
        <hr />
        <details>
          <summary>
            <h3>Resend receipt</h3>
          </summary>
          <AdminResendReceiptForm purchase_id={purchase.id} email={purchase.email} />
        </details>
      </>
    ) : null}
    <hr />
    <ActionButtons purchase={purchase} />
    <AdminCommentableComments
      count={purchase.comments_count}
      endpoint={Routes.admin_purchase_comments_path(purchase.id)}
      commentableType="purchase"
    />
    <hr />
    <dl>
      <dt>Updated</dt>
      <dd>
        <DateTimeWithRelativeTooltip date={purchase.updated_at} />
      </dd>
      <dt>Deleted</dt>
      <dd>
        <DateTimeWithRelativeTooltip date={purchase.deleted_at} placeholder={<NoIcon />} />
      </dd>
    </dl>
  </div>
);

export default AdminPurchase;
