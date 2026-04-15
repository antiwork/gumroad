import { ArrowDown, ArrowUpRightSquare, Paperclip, Trash } from "@boxicons/react";
import { Deferred, Link } from "@inertiajs/react";
import { Blob, DirectUpload } from "@rails/activestorage";
import * as React from "react";

import {
  Address,
  Call,
  Charge,
  Commission,
  Customer,
  CustomerEmail,
  Discount,
  File,
  License,
  MissedPost,
  Option,
  Review,
  ReviewVideo,
  Tracking,
  approveReviewVideo,
  cancelSubscription,
  changeCanContact,
  completeCommission,
  getCharges,
  getOptions,
  markShipped,
  refund,
  rejectReviewVideo,
  resendPing,
  resendPost,
  resendReceipt,
  revokeAccess,
  undoRevokeAccess,
  updateCallUrl,
  updateCommission,
  updateLicense,
  updateOption,
  updatePurchase,
} from "$app/data/customers";
import {
  CurrencyCode,
  formatPriceCentsWithCurrencySymbol,
  formatPriceCentsWithoutCurrencySymbol,
  getIsSingleUnitCurrency,
} from "$app/utils/currency";
import { formatCallDate } from "$app/utils/date";
import { isValidEmail } from "$app/utils/email";
import FileUtils from "$app/utils/file";
import { priceCentsToUnit } from "$app/utils/price";
import { asyncVoid } from "$app/utils/promise";
import { RecurrenceId, recurrenceLabels } from "$app/utils/recurringPricing";
import { assertResponseError } from "$app/utils/request";

import { Button, NavigationButton, buttonVariants } from "$app/components/Button";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { FileKindIcon } from "$app/components/FileRowContent";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Modal } from "$app/components/Modal";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { NumberInput } from "$app/components/NumberInput";
import { PriceInput } from "$app/components/PriceInput";
import { RatingStars } from "$app/components/RatingStars";
import { ReviewResponseForm } from "$app/components/ReviewResponseForm";
import { ReviewVideoPlayer } from "$app/components/ReviewVideoPlayer";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Card, CardContent } from "$app/components/ui/Card";
import { Checkbox } from "$app/components/ui/Checkbox";
import { DefinitionList } from "$app/components/ui/DefinitionList";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { InlineList } from "$app/components/ui/InlineList";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Pill } from "$app/components/ui/Pill";
import { Row, RowActions, RowContent, Rows } from "$app/components/ui/Rows";
import { Select as FormSelect } from "$app/components/ui/Select";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { useRunOnce } from "$app/components/useRunOnce";
import { WithTooltip } from "$app/components/WithTooltip";

export type CustomerDetailPageProps = {
  customer: Customer;
  countries: string[];
  can_ping: boolean;
  show_refund_fee_notice: boolean;
  emails: CustomerEmail[];
  missed_posts?: MissedPost[];
  charges: Charge[];
  product_purchases: Customer[];
};

const year = new Date().getFullYear();

const formatPrice = (priceCents: number, currencyType: CurrencyCode, recurrence?: RecurrenceId | null) =>
  `${formatPriceCentsWithCurrencySymbol(currencyType, priceCents, { symbolFormat: "long" })}${
    recurrence ? ` ${recurrenceLabels[recurrence]}` : ""
  }`;

const formatDiscount = (discount: Discount, currencyType: CurrencyCode) =>
  discount.type === "fixed"
    ? formatPriceCentsWithCurrencySymbol(currencyType, discount.cents, {
        symbolFormat: "short",
      })
    : `${discount.percents}%`;

const MEMBERSHIP_STATUS_LABELS = {
  alive: "Active",
  cancelled: "Cancelled",
  failed_payment: "Failed payment",
  fixed_subscription_period_ended: "Ended",
  pending_cancellation: "Cancellation pending",
  pending_failure: "Failure pending",
};

const INSTALLMENT_PLAN_STATUS_LABELS = {
  alive: "In progress",
  cancelled: "Cancelled",
  failed_payment: "Payment failed",
  fixed_subscription_period_ended: "Paid in full",
  pending_cancellation: "Cancellation pending",
  pending_failure: "Failure pending",
};

const PAGE_SIZE = 10;

const CustomerDetailPage = ({
  customer: initialCustomer,
  countries,
  can_ping: canPing,
  show_refund_fee_notice: showRefundFeeNotice,
  emails: initialEmails,
  missed_posts: initialMissedPosts,
  charges: initialCharges,
  product_purchases: initialProductPurchases,
}: CustomerDetailPageProps) => {
  const userAgentInfo = useUserAgentInfo();
  const currentSeller = useCurrentSeller();

  const [customer, setCustomer] = React.useState(initialCustomer);
  const updateCustomer = (update: Partial<Customer>) => setCustomer((prev) => ({ ...prev, ...update }));

  const [loadingId, setLoadingId] = React.useState<string | null>(null);
  const missedPosts = initialMissedPosts ?? [];
  const [shownMissedPosts, setShownMissedPosts] = React.useState(PAGE_SIZE);
  const emails = initialEmails;
  const [shownEmails, setShownEmails] = React.useState(PAGE_SIZE);
  const sentEmailIds = React.useRef<Set<string>>(new Set());

  const onSend = async (id: string, type: "receipt" | "post") => {
    setLoadingId(id);
    try {
      await (type === "receipt" ? resendReceipt(id) : resendPost(customer.id, id));
      sentEmailIds.current.add(id);
      showAlert(type === "receipt" ? "Receipt resent" : "Email Sent", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setLoadingId(null);
  };

  const [productPurchases, setProductPurchases] = React.useState<Customer[]>(initialProductPurchases);

  const { subscription, commission, license, shipping } = customer;

  const showCharges = subscription || commission;
  const [charges, setCharges] = React.useState<Charge[]>(initialCharges);

  const isCoffee = customer.product.native_type === "coffee";

  const formatDateWithoutTime = (date: Date) =>
    date.toLocaleDateString(userAgentInfo.locale, {
      day: "numeric",
      month: "short",
      year: date.getFullYear() !== year ? "numeric" : undefined,
      timeZone: currentSeller?.timeZone.name,
    });

  const statusPills = (
    <>
      {commission ? <CommissionStatusPill commission={commission} /> : null}
      {customer.refunded ? (
        <Pill size="small" color="danger">
          Refunded
        </Pill>
      ) : null}
      {customer.partially_refunded ? <Pill size="small">Partially refunded</Pill> : null}
      {customer.chargedback ? (
        <Pill size="small" color="danger">
          Chargedback
        </Pill>
      ) : null}
      {customer.is_preorder ? <Pill size="small">Pre-order</Pill> : null}
      {customer.is_additional_contribution ? <Pill size="small">Additional contribution</Pill> : null}
      {customer.is_bundle_purchase ? <Pill size="small">Bundle</Pill> : null}
      {subscription?.is_installment_plan ? <Pill size="small">Installments</Pill> : null}
      {subscription && !subscription.is_installment_plan && subscription.status !== "alive" ? (
        <Pill size="small">Inactive</Pill>
      ) : null}
    </>
  );

  return (
    <div className="h-full">
      <PageHeader
        showTitleOnMobile
        title={
          <div className="flex flex-wrap items-center gap-2">
            <Link href="/customers" aria-label="Back to customers" className="mr-4 hidden no-underline sm:inline">
              ←
            </Link>
            {customer.product.name}
            {statusPills}
          </div>
        }
      />

      <ColumnLayout className="flex flex-col gap-8 p-4 md:p-8">
        {customer.is_additional_contribution ? (
          <div className="break-inside-avoid">
            <Alert role="status" variant="info">
              <strong>Additional amount: </strong>This is an additional contribution, added to a previous purchase of
              this product.
            </Alert>
          </div>
        ) : null}
        {customer.ppp ? (
          <div className="break-inside-avoid">
            <Alert role="status" variant="info">
              This customer received a purchasing power parity discount of <b>{customer.ppp.discount}</b> because they
              are located in <b>{customer.ppp.country}</b>.
            </Alert>
          </div>
        ) : null}
        {customer.giftee_email ? (
          <div className="break-inside-avoid">
            <Alert role="status" variant="info">
              {customer.email} purchased this for {customer.giftee_email}.
            </Alert>
          </div>
        ) : null}
        {customer.is_preorder ? (
          <div className="break-inside-avoid">
            <Alert role="status" variant="info">
              <strong>Pre-order: </strong>This is a pre-order authorization. The customer's card has not been charged
              yet.
            </Alert>
          </div>
        ) : null}
        {customer.affiliate && customer.affiliate.type !== "Collaborator" ? (
          <div className="break-inside-avoid">
            <Alert role="status" variant="info">
              <strong>Affiliate: </strong>An affiliate ({customer.affiliate.email}) helped you make this sale and
              received {customer.affiliate.amount}.
            </Alert>
          </div>
        ) : null}
        <div className="break-inside-avoid">
          <EmailSection
            label="Email"
            email={customer.email}
            onSave={
              customer.is_existing_user
                ? null
                : (email) =>
                    updatePurchase(customer.id, { email }).then(
                      () => {
                        showAlert("Email updated successfully.", "success");
                        updateCustomer({ email });
                        if (productPurchases.length)
                          setProductPurchases((prevProductPurchases) =>
                            prevProductPurchases.map((productPurchase) => ({ ...productPurchase, email })),
                          );
                      },
                      (e: unknown) => {
                        assertResponseError(e);
                        showAlert(e.message, "error");
                      },
                    )
            }
            canContact={customer.can_contact}
            onChangeCanContact={(canContact) =>
              changeCanContact(customer.id, canContact).then(
                () => {
                  showAlert(
                    canContact
                      ? "Your customer will now receive your posts."
                      : "Your customer will no longer receive your posts.",
                    "success",
                  );
                  updateCustomer({ can_contact: canContact });
                },
                (e: unknown) => {
                  assertResponseError(e);
                  showAlert(e.message, "error");
                },
              )
            }
          />
        </div>
        {customer.giftee_email ? (
          <div className="break-inside-avoid">
            <EmailSection
              label="Giftee email"
              email={customer.giftee_email}
              onSave={(email) =>
                updatePurchase(customer.id, { giftee_email: email }).then(
                  () => {
                    showAlert("Email updated successfully.", "success");
                    updateCustomer({ giftee_email: email });
                  },
                  (e: unknown) => {
                    assertResponseError(e);
                    showAlert(e.message, "error");
                  },
                )
              }
            />
          </div>
        ) : null}
        <Card asChild>
          <section className="break-inside-avoid">
            <CardContent asChild>
              <h3 className="flex gap-1">
                Order information
                {!subscription && customer.transaction_url_for_seller ? (
                  <a
                    href={customer.transaction_url_for_seller}
                    target="_blank"
                    rel="noreferrer"
                    aria-label="Transaction"
                    className="grow"
                  >
                    <ArrowUpRightSquare className="size-5" />
                  </a>
                ) : null}
              </h3>
            </CardContent>
            <CardContent>
              <h5 className="grow font-bold">Customer name</h5>
              {customer.name || customer.email}
            </CardContent>
            <CardContent>
              <h5 className="grow font-bold">{customer.is_multiseat_license ? "Seats" : "Quantity"}</h5>
              {customer.quantity}
            </CardContent>
            {customer.download_count ? (
              <CardContent>
                <h5 className="grow font-bold">Download count</h5>
                {customer.download_count}
              </CardContent>
            ) : null}
            <CardContent>
              <h5 className="grow font-bold">Price</h5>
              <div>
                {customer.price.cents_before_offer_code > customer.price.cents ? (
                  <>
                    <s>
                      {formatPrice(
                        customer.price.cents_before_offer_code,
                        customer.price.currency_type,
                        customer.price.recurrence,
                      )}
                    </s>{" "}
                  </>
                ) : null}
                {formatPrice(
                  customer.price.cents - (customer.price.tip_cents ?? 0),
                  customer.price.currency_type,
                  customer.price.recurrence,
                )}
              </div>
            </CardContent>
            {customer.price.tip_cents ? (
              <CardContent>
                <h5 className="grow font-bold">Tip</h5>
                {formatPrice(customer.price.tip_cents, customer.price.currency_type, customer.price.recurrence)}
              </CardContent>
            ) : null}
            {customer.discount && !customer.upsell ? (
              <CardContent>
                <h5 className="grow font-bold">Discount</h5>
                {customer.discount.code ? (
                  <div>
                    {formatDiscount(customer.discount, customer.price.currency_type)} off with code{" "}
                    <Pill size="small">{customer.discount.code.toUpperCase()}</Pill>
                  </div>
                ) : (
                  `${formatDiscount(customer.discount, customer.price.currency_type)} off`
                )}
              </CardContent>
            ) : null}
            {customer.upsell ? (
              <CardContent>
                <h5 className="grow font-bold">Upsell</h5>
                {`${customer.upsell}${
                  customer.discount ? ` (${formatDiscount(customer.discount, customer.price.currency_type)} off)` : ""
                }`}
              </CardContent>
            ) : null}
            {subscription?.status ? (
              <CardContent>
                <h5 className="grow font-bold">
                  {subscription.is_installment_plan ? "Installment plan status" : "Membership status"}
                </h5>
                <div
                  style={{
                    color:
                      subscription.status === "alive" || subscription.status === "fixed_subscription_period_ended"
                        ? undefined
                        : "var(--red)",
                  }}
                >
                  {subscription.is_installment_plan
                    ? INSTALLMENT_PLAN_STATUS_LABELS[subscription.status]
                    : MEMBERSHIP_STATUS_LABELS[subscription.status]}
                </div>
              </CardContent>
            ) : null}
            {customer.referrer ? (
              <CardContent>
                <h5 className="grow font-bold">Referrer</h5>
                {customer.referrer}
              </CardContent>
            ) : null}
            {customer.physical ? (
              <>
                <CardContent>
                  <h5 className="grow font-bold">SKU</h5>
                  {customer.physical.sku}
                </CardContent>
                <CardContent>
                  <h5 className="grow font-bold">Order number</h5>
                  {customer.physical.order_number}
                </CardContent>
              </>
            ) : null}
          </section>
        </Card>
        {customer.utm_link ? (
          <div className="break-inside-avoid">
            <UtmLinkCard link={customer.utm_link} />
          </div>
        ) : null}
        {customer.review ? (
          <div className="break-inside-avoid">
            <ReviewSection
              review={customer.review}
              purchaseId={customer.id}
              onChange={(updatedReview) => updateCustomer({ review: updatedReview })}
            />
          </div>
        ) : null}
        {customer.custom_fields.length > 0 ? (
          <Card asChild>
            <section className="break-inside-avoid">
              <CardContent asChild>
                <header>
                  <h3 className="grow">Information provided</h3>
                </header>
              </CardContent>
              {customer.custom_fields.map((field, idx) => {
                const content = (
                  <CardContent asChild>
                    <section key={idx}>
                      <h5 className="grow font-bold">{field.attribute}</h5>
                      {field.type === "text" ? (
                        field.value
                      ) : (
                        <Rows role="list" className="mt-2">
                          {field.files.map((file) => (
                            <FileRow file={file} key={file.key} />
                          ))}
                        </Rows>
                      )}
                    </section>
                  </CardContent>
                );
                return field.type === "file" ? <div key={idx}>{content}</div> : content;
              })}
            </section>
          </Card>
        ) : null}
        {customer.has_options && !isCoffee && customer.product.native_type !== "call" ? (
          <div className="break-inside-avoid">
            <OptionSection
              option={customer.option}
              onChange={(option) => updateCustomer({ option })}
              purchaseId={customer.id}
              productPermalink={customer.product.permalink}
              isSubscription={!!subscription}
              quantity={customer.quantity}
            />
          </div>
        ) : null}
        {customer.is_bundle_purchase ? (
          <Card asChild>
            <section className="break-inside-avoid">
              <CardContent asChild>
                <header>
                  <h3 className="grow">Content</h3>
                </header>
              </CardContent>
              {productPurchases.length > 0 ? (
                productPurchases.map((productPurchase) => (
                  <CardContent asChild key={productPurchase.id}>
                    <section>
                      <h5 className="grow font-bold">{productPurchase.product.name}</h5>
                      <NavigationButtonInertia href={Routes.customer_sale_path(productPurchase.id)}>
                        Manage
                      </NavigationButtonInertia>
                    </section>
                  </CardContent>
                ))
              ) : (
                <CardContent asChild>
                  <section>
                    <div className="grow text-center">
                      <LoadingSpinner className="size-8" />
                    </div>
                  </section>
                </CardContent>
              )}
            </section>
          </Card>
        ) : null}
        {license ? (
          <div className="break-inside-avoid">
            <LicenseSection
              license={license}
              onSave={(enabled) =>
                updateLicense(license.id, enabled).then(
                  () => {
                    showAlert("Changes saved!", "success");
                    updateCustomer({ license: { ...license, enabled } });
                  },
                  (e: unknown) => {
                    assertResponseError(e);
                    showAlert(e.message, "error");
                  },
                )
              }
            />
          </div>
        ) : null}
        {customer.is_multiseat_license ? (
          <div className="break-inside-avoid">
            <SeatSection
              seats={customer.quantity}
              onSave={(quantity) =>
                updatePurchase(customer.id, { quantity }).then(
                  () => {
                    showAlert("Successfully updated seats!", "success");
                    updateCustomer({ quantity });
                  },
                  (e: unknown) => {
                    assertResponseError(e);
                    showAlert(e.message, "error");
                  },
                )
              }
            />
          </div>
        ) : null}
        {shipping ? (
          <Card className="break-inside-avoid">
            <CardContent>
              <TrackingSection
                tracking={shipping.tracking}
                onMarkShipped={(url) =>
                  markShipped(customer.id, url).then(
                    () => {
                      showAlert("Changes saved!", "success");
                      updateCustomer({ shipping: { ...shipping, tracking: { url, shipped: true } } });
                    },
                    (e: unknown) => {
                      assertResponseError(e);
                      showAlert(e.message, "error");
                    },
                  )
                }
              />
            </CardContent>
            <CardContent>
              <AddressSection
                address={shipping.address}
                price={shipping.price}
                onSave={(address) =>
                  updatePurchase(customer.id, address).then(
                    () => {
                      showAlert("Changes saved!", "success");
                      updateCustomer({ shipping: { ...shipping, address } });
                    },
                    (e: unknown) => {
                      assertResponseError(e);
                      showAlert(e.message, "error");
                    },
                  )
                }
                countries={countries}
              />
            </CardContent>
          </Card>
        ) : null}
        {customer.call ? (
          <div className="break-inside-avoid">
            <CallSection call={customer.call} onChange={(call) => updateCustomer({ call })} />
          </div>
        ) : null}
        {!showCharges && !customer.refunded && !customer.chargedback && customer.price.cents_refundable > 0 ? (
          <Card asChild>
            <section className="break-inside-avoid">
              <CardContent asChild>
                <header>
                  <h3 className="grow">Refund</h3>
                </header>
              </CardContent>
              <CardContent asChild>
                <section>
                  <RefundForm
                    purchaseId={customer.id}
                    currencyType={customer.price.currency_type}
                    amountRefundable={customer.price.cents_refundable}
                    showRefundFeeNotice={showRefundFeeNotice}
                    paypalRefundExpired={customer.paypal_refund_expired}
                    modalTitle="Purchase refund"
                    modalText="Would you like to confirm this purchase refund?"
                    onChange={(amountRefundable) =>
                      updateCustomer({
                        price: { ...customer.price, cents_refundable: amountRefundable },
                        refunded: amountRefundable === 0,
                        partially_refunded: amountRefundable > 0 && amountRefundable < customer.price.cents_refundable,
                      })
                    }
                    className="grow basis-0"
                  />
                </section>
              </CardContent>
            </section>
          </Card>
        ) : null}
        {subscription?.status === "alive" ? (
          <div className="break-inside-avoid">
            <SubscriptionCancellationSection
              isInstallmentPlan={subscription.is_installment_plan}
              onCancel={() =>
                void cancelSubscription(subscription.id).then(
                  () => {
                    showAlert("Changes saved!", "success");
                    updateCustomer({ subscription: { ...subscription, status: "pending_cancellation" } });
                  },
                  (e: unknown) => {
                    assertResponseError(e);
                    showAlert(e.message, "error");
                  },
                )
              }
            />
          </div>
        ) : null}
        {canPing && !subscription ? (
          <Card asChild>
            <section className="break-inside-avoid">
              <CardContent>
                <PingButton purchaseId={customer.id} className="grow basis-0" />
              </CardContent>
            </section>
          </Card>
        ) : null}
        {customer.is_access_revoked !== null && !isCoffee && !commission ? (
          <div className="break-inside-avoid">
            <AccessSection
              purchaseId={customer.id}
              onChange={(isAccessRevoked) => updateCustomer({ is_access_revoked: isAccessRevoked })}
              isAccessRevoked={customer.is_access_revoked}
            />
          </div>
        ) : null}
        {showCharges ? (
          <div className="break-inside-avoid">
            <ChargesSection
              charges={charges}
              remainingCharges={subscription?.remaining_charges ?? null}
              onChange={setCharges}
              showRefundFeeNotice={showRefundFeeNotice}
              canPing={canPing}
              customerEmail={customer.email}
              loading={false}
            />
          </div>
        ) : null}
        {commission ? (
          <div className="break-inside-avoid">
            <CommissionSection commission={commission} onChange={(commission) => {
              updateCustomer({ commission });
              if (commission.status === "completed") {
                void getCharges(customer.id, customer.email).then(setCharges);
              }
            }} />
          </div>
        ) : null}
        {emails.length !== 0 ? (
          <Card asChild>
            <section className="break-inside-avoid">
              <CardContent asChild>
                <header>
                  <h3 className="grow">Emails received</h3>
                </header>
              </CardContent>
              {emails.slice(0, shownEmails).map((email) => (
                <CardContent asChild key={email.id}>
                  <section>
                    <div className="grow">
                      <h5>
                        {email.type === "receipt" ? (
                          <a href={email.url} target="_blank" rel="noreferrer">
                            {email.name}
                          </a>
                        ) : (
                          email.name
                        )}
                      </h5>
                      <small className="block text-muted">{`${email.state} ${formatDateWithoutTime(new Date(email.state_at))}`}</small>
                    </div>
                    {email.type === "receipt" ? (
                      <Button
                        color="primary"
                        onClick={() => void onSend(email.id, "receipt")}
                        disabled={!!loadingId || sentEmailIds.current.has(email.id)}
                      >
                        {sentEmailIds.current.has(email.id)
                          ? "Receipt resent"
                          : loadingId === email.id
                            ? "Resending receipt..."
                            : "Resend receipt"}
                      </Button>
                    ) : (
                      <Button
                        color="primary"
                        onClick={() => void onSend(email.id, "post")}
                        disabled={!!loadingId || sentEmailIds.current.has(email.id)}
                      >
                        {sentEmailIds.current.has(email.id)
                          ? "Sent"
                          : loadingId === email.id
                            ? "Sending..."
                            : "Resend email"}
                      </Button>
                    )}
                  </section>
                </CardContent>
              ))}
              {shownEmails < emails.length ? (
                <CardContent asChild>
                  <section>
                    <Button onClick={() => setShownEmails((prev) => prev + PAGE_SIZE)} className="grow basis-0">
                      Load more
                    </Button>
                  </section>
                </CardContent>
              ) : null}
            </section>
          </Card>
        ) : null}
        <div className="break-inside-avoid">
          <Deferred data={["missed_posts"]} fallback={
            <Card asChild>
              <section>
                <CardContent asChild>
                  <header>
                    <h3 className="grow">Send missed posts</h3>
                  </header>
                </CardContent>
                <CardContent>
                  <LoadingSpinner className="mx-auto size-8" />
                </CardContent>
              </section>
            </Card>
          }>
            {missedPosts.length !== 0 ? (
              <Card asChild>
                <section>
                  <CardContent asChild>
                    <header>
                      <h3 className="grow">Send missed posts</h3>
                    </header>
                  </CardContent>
                  {missedPosts.slice(0, shownMissedPosts).map((post) => (
                    <CardContent asChild key={post.id}>
                      <section>
                        <div className="grow">
                          <h5 className="font-bold">
                            <a href={post.url} target="_blank" rel="noreferrer">
                              {post.name}
                            </a>
                          </h5>
                          <small className="block text-muted">{`Originally sent on ${formatDateWithoutTime(new Date(post.published_at))}`}</small>
                        </div>
                        <Button
                          color="primary"
                          disabled={!!loadingId || sentEmailIds.current.has(post.id)}
                          onClick={() => void onSend(post.id, "post")}
                        >
                          {sentEmailIds.current.has(post.id) ? "Sent" : loadingId === post.id ? "Sending..." : "Send"}
                        </Button>
                      </section>
                    </CardContent>
                  ))}
                  {shownMissedPosts < missedPosts.length ? (
                    <CardContent asChild>
                      <section>
                        <Button onClick={() => setShownMissedPosts((prev) => prev + PAGE_SIZE)} className="grow basis-0">
                          Show more
                        </Button>
                      </section>
                    </CardContent>
                  ) : null}
                </section>
              </Card>
            ) : null}
          </Deferred>
        </div>
      </ColumnLayout>
    </div>
  );
};

const CommissionStatusPill = ({ commission }: { commission: Commission }) => (
  <Pill
    size="small"
    color={commission.status === "completed" ? "primary" : commission.status === "cancelled" ? "danger" : undefined}
  >
    {commission.status === "in_progress"
      ? "In progress"
      : commission.status === "completed"
        ? "Completed"
        : "Cancelled"}
  </Pill>
);

const UtmLinkCard = ({ link }: { link: Customer["utm_link"] }) => {
  if (!link) return null;

  return (
    <Card asChild>
      <section>
        <CardContent asChild>
          <section>
            <h3 className="grow">UTM link</h3>
          </section>
        </CardContent>
        <CardContent>
          <Alert className="grow text-sm" role="status" variant="info">
            This sale was driven by a{" "}
            <a href={link.utm_url} target="_blank" rel="noreferrer">
              UTM link
            </a>
            .
          </Alert>
        </CardContent>
        <CardContent>
          <DefinitionList>
            <dt>Title</dt>
            <dd>
              <a href={Routes.dashboard_utm_links_path({ query: link.title })} target="_blank" rel="noreferrer">
                {link.title}
              </a>
            </dd>
            <dt>Source</dt>
            <dd>{link.source}</dd>
            <dt>Medium</dt>
            <dd>{link.medium}</dd>
            <dt>Campaign</dt>
            <dd>{link.campaign}</dd>
            {link.term ? (
              <>
                <dt>Term</dt>
                <dd>{link.term}</dd>
              </>
            ) : null}
            {link.content ? (
              <>
                <dt>Content</dt>
                <dd>{link.content}</dd>
              </>
            ) : null}
          </DefinitionList>
        </CardContent>
      </section>
    </Card>
  );
};

const AddressSection = ({
  address: currentAddress,
  price,
  onSave,
  countries,
}: {
  address: Address;
  price: string;
  onSave: (address: Address) => Promise<void>;
  countries: string[];
}) => {
  const uid = React.useId();
  const [address, setAddress] = React.useState(currentAddress);
  const updateShipping = (update: Partial<Address>) => setAddress((prev) => ({ ...prev, ...update }));
  const [isEditing, setIsEditing] = React.useState(false);
  const [isLoading, setIsLoading] = React.useState(false);

  const handleSave = async () => {
    setIsLoading(true);
    await onSave(address);
    setIsLoading(false);
    setIsEditing(false);
  };

  return (
    <section className="grow">
      <div className="mb-4 flex items-center gap-2">
        <h3 className="grow">Shipping address</h3>
        {!isEditing ? (
          <button className="cursor-pointer text-sm underline all-unset" onClick={() => setIsEditing(true)}>
            Edit
          </button>
        ) : null}
      </div>
      {isEditing ? (
        <div className="flex flex-col gap-4">
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-full-name`}>Full name</Label>
            </FieldsetTitle>
            <Input
              id={`${uid}-full-name`}
              type="text"
              placeholder="Full name"
              value={address.full_name}
              onChange={(evt) => updateShipping({ full_name: evt.target.value })}
            />
          </Fieldset>
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-street-address`}>Street address</Label>
            </FieldsetTitle>
            <Input
              id={`${uid}-street-address`}
              type="text"
              placeholder="Street address"
              value={address.street_address}
              onChange={(evt) => updateShipping({ street_address: evt.target.value })}
            />
          </Fieldset>
          <div className="grid grid-cols-3 gap-2">
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-city`}>City</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-city`}
                type="text"
                placeholder="City"
                value={address.city}
                onChange={(evt) => updateShipping({ city: evt.target.value })}
              />
            </Fieldset>
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-state`}>State</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-state`}
                type="text"
                placeholder="State"
                value={address.state}
                onChange={(evt) => updateShipping({ state: evt.target.value })}
              />
            </Fieldset>
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-zip-code`}>ZIP code</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-zip-code`}
                type="text"
                placeholder="ZIP code"
                value={address.zip_code}
                onChange={(evt) => updateShipping({ zip_code: evt.target.value })}
              />
            </Fieldset>
          </div>
          <Fieldset>
            <Label htmlFor={`${uid}-country`}>Country</Label>
            <FormSelect
              id={`${uid}-country`}
              value={address.country}
              onChange={(evt) => updateShipping({ country: evt.target.value })}
            >
              {countries.map((country) => (
                <option value={country} key={country}>
                  {country}
                </option>
              ))}
            </FormSelect>
          </Fieldset>
          <div className="flex gap-2">
            <Button onClick={() => setIsEditing(false)} disabled={isLoading} className="flex-1">
              Cancel
            </Button>
            <Button color="primary" onClick={() => void handleSave()} disabled={isLoading} className="flex-1">
              Save
            </Button>
          </div>
        </div>
      ) : (
        <div>
          <p>
            {currentAddress.full_name}
            <br />
            {currentAddress.street_address}
            <br />
            {`${currentAddress.city}, ${currentAddress.state} ${currentAddress.zip_code}`}
            <br />
            {currentAddress.country}
          </p>
          <p className="mt-2 text-sm text-muted">Shipping charged {price}</p>
        </div>
      )}
    </section>
  );
};

const TrackingSection = ({
  tracking,
  onMarkShipped,
}: {
  tracking: Tracking;
  onMarkShipped: (url: string) => Promise<void>;
}) => {
  const [url, setUrl] = React.useState((tracking.shipped ? tracking.url : "") ?? "");
  const [isLoading, setIsLoading] = React.useState(false);

  const handleSave = async () => {
    setIsLoading(true);
    await onMarkShipped(url);
    setIsLoading(false);
  };

  return (
    <section className="grow">
      <h3 className="mb-4">Tracking information</h3>
      {tracking.shipped ? (
        tracking.url ? (
          <NavigationButton color="primary" href={tracking.url} target="_blank" className="w-full">
            Track shipment
          </NavigationButton>
        ) : (
          <Alert role="status" variant="success">
            Shipped
          </Alert>
        )
      ) : (
        <Fieldset>
          <Input
            type="text"
            placeholder="Tracking URL (optional)"
            value={url}
            onChange={(evt) => setUrl(evt.target.value)}
          />
          <Button color="primary" disabled={isLoading} onClick={() => void handleSave()}>
            Mark as shipped
          </Button>
        </Fieldset>
      )}
    </section>
  );
};

const EmailSection = ({
  label,
  email: currentEmail,
  onSave,
  canContact,
  onChangeCanContact,
}: {
  label: string;
  email: string;
  onSave: ((email: string) => Promise<void>) | null;
  canContact?: boolean;
  onChangeCanContact?: (canContact: boolean) => Promise<void>;
}) => {
  const [email, setEmail] = React.useState(currentEmail);
  const [isEditing, setIsEditing] = React.useState(false);
  const [isLoading, setIsLoading] = React.useState(false);

  const handleSave = async () => {
    if (!onSave) return;

    const emailError =
      email.length === 0 ? "Email must be provided" : !isValidEmail(email) ? "Please enter a valid email" : null;

    if (emailError) {
      showAlert(emailError, "error");
      return;
    }

    setIsLoading(true);
    await onSave(email);
    setIsLoading(false);
    setIsEditing(false);
  };

  return (
    <Card asChild>
      <section>
        <CardContent asChild>
          <header>
            <h3 className="grow">{label}</h3>
          </header>
        </CardContent>
        {isEditing ? (
          <CardContent asChild>
            <Fieldset>
              <Input
                type="text"
                value={email}
                onChange={(evt) => setEmail(evt.target.value)}
                disabled={isLoading}
                placeholder={label}
                className="grow"
              />
              <div className="flex w-full gap-2">
                <Button onClick={() => setIsEditing(false)} disabled={isLoading} className="flex-1">
                  Cancel
                </Button>
                <Button color="primary" onClick={() => void handleSave()} disabled={isLoading} className="flex-1">
                  Save
                </Button>
              </div>
            </Fieldset>
          </CardContent>
        ) : (
          <CardContent asChild>
            <section>
              <h5 className="grow font-bold">{currentEmail}</h5>
              {onSave ? (
                <button className="cursor-pointer underline all-unset" onClick={() => setIsEditing(true)}>
                  Edit
                </button>
              ) : (
                <small className="block text-muted">
                  You cannot change the email of this purchase, because it was made by an existing user. Please ask them
                  to go to gumroad.com/settings to update their email.
                </small>
              )}
            </section>
          </CardContent>
        )}
        {onChangeCanContact ? (
          <CardContent asChild>
            <section>
              <Fieldset role="group" className="grow basis-0">
                <Label>
                  Receives emails
                  <Checkbox
                    wrapperClassName="ml-auto"
                    checked={canContact}
                    onChange={(evt) => {
                      setIsLoading(true);
                      void onChangeCanContact(evt.target.checked).then(() => setIsLoading(false));
                    }}
                    disabled={isLoading}
                  />
                </Label>
              </Fieldset>
            </section>
          </CardContent>
        ) : null}
      </section>
    </Card>
  );
};

const ReviewVideosSubsections = ({
  review,
  onChange,
  className,
}: {
  review: Review;
  className?: string;
  onChange: (review: Review) => void;
}) => {
  const [loading, setLoading] = React.useState(false);
  const [approvedVideoRemovalModalOpen, setApprovedVideoRemovalModalOpen] = React.useState(false);

  const approvedVideo = review.videos.find((video) => video.approval_status === "approved");
  const pendingVideo = review.videos.find((video) => video.approval_status === "pending_review");

  const approveVideo = async (video: ReviewVideo) => {
    setLoading(true);
    try {
      await approveReviewVideo(video.id);
      onChange({ ...review, videos: [{ ...video, approval_status: "approved" }] });
      showAlert("This video is now live!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert("Something went wrong", "error");
    } finally {
      setLoading(false);
    }
  };

  const rejectVideo = async (video: ReviewVideo) => {
    setLoading(true);
    try {
      await rejectReviewVideo(video.id);
      const otherVideos = review.videos.filter((v) => v.id !== video.id);
      onChange({ ...review, videos: [{ ...video, approval_status: "rejected" }, ...otherVideos] });
      showAlert("This video has been removed.", "success");
      setApprovedVideoRemovalModalOpen(false);
    } catch (e) {
      assertResponseError(e);
      showAlert("Something went wrong", "error");
    } finally {
      setLoading(false);
    }
  };

  const approvedVideoSubsection = approvedVideo ? (
    <section className={className}>
      <div className="flex flex-col gap-4">
        <h5>Approved video</h5>
        <ReviewVideoPlayer videoId={approvedVideo.id} thumbnail={approvedVideo.thumbnail_url} />
        <Button onClick={() => setApprovedVideoRemovalModalOpen(true)} disabled={loading}>
          Remove
        </Button>
        <Modal
          open={approvedVideoRemovalModalOpen}
          onClose={() => setApprovedVideoRemovalModalOpen(false)}
          title="Remove approved video?"
          footer={
            <>
              <Button onClick={() => setApprovedVideoRemovalModalOpen(false)} disabled={loading}>
                Cancel
              </Button>
              <Button color="danger" onClick={() => void rejectVideo(approvedVideo)} disabled={loading}>
                Remove video
              </Button>
            </>
          }
        >
          <p>This action cannot be undone. This video will be permanently removed from this review.</p>
        </Modal>
      </div>
    </section>
  ) : null;

  const pendingVideoSubsection = pendingVideo ? (
    <section>
      <div className="flex flex-col gap-4">
        <h5>Pending video</h5>
        <ReviewVideoPlayer videoId={pendingVideo.id} thumbnail={pendingVideo.thumbnail_url} />
        <div className="flex flex-row gap-2">
          {pendingVideo.can_approve ? (
            <Button
              color="primary"
              className="flex-1"
              onClick={() => void approveVideo(pendingVideo)}
              disabled={loading}
            >
              Approve
            </Button>
          ) : null}
          {pendingVideo.can_reject ? (
            <Button color="danger" className="flex-1" onClick={() => void rejectVideo(pendingVideo)} disabled={loading}>
              Reject
            </Button>
          ) : null}
        </div>
      </div>
    </section>
  ) : null;

  return approvedVideoSubsection || pendingVideoSubsection ? (
    <>
      {approvedVideoSubsection}
      {pendingVideoSubsection}
    </>
  ) : null;
};

const ReviewSection = ({
  review,
  purchaseId,
  onChange,
}: {
  review: Review;
  purchaseId: string;
  onChange: (review: Review) => void;
}) => (
  <Card asChild>
    <section>
      <CardContent asChild>
        <h3>Review</h3>
      </CardContent>
      <CardContent asChild>
        <section>
          <h5 className="grow font-bold">Rating</h5>
          <div aria-label={`${review.rating} ${review.rating === 1 ? "star" : "stars"}`}>
            <RatingStars rating={review.rating} />
          </div>
        </section>
      </CardContent>
      {review.message ? (
        <CardContent asChild>
          <section>
            <h5 className="grow font-bold">Message</h5>
            {review.message}
          </section>
        </CardContent>
      ) : null}
      <CardContent asChild>
        <ReviewVideosSubsections review={review} onChange={onChange} className="grow" />
      </CardContent>
      {review.response ? (
        <CardContent asChild>
          <section>
            <h5 className="grow font-bold">Response</h5>
            {review.response.message}
          </section>
        </CardContent>
      ) : null}
      <CardContent>
        <ReviewResponseForm
          message={review.response?.message}
          purchaseId={purchaseId}
          onChange={(response) => onChange({ ...review, response })}
          className="w-full"
        />
      </CardContent>
    </section>
  </Card>
);

const OptionSection = ({
  option,
  onChange,
  purchaseId,
  productPermalink,
  isSubscription,
  quantity,
}: {
  option: Option | null;
  onChange: (option: Option) => void;
  purchaseId: string;
  productPermalink: string;
  isSubscription: boolean;
  quantity: number;
}) => {
  const [options, setOptions] = React.useState<Option[]>([]);
  const [selectedOptionId, setSelectedOptionId] = React.useState<{ value: string | null; error?: boolean }>({
    value: option?.id ?? null,
  });
  const [isEditing, setIsEditing] = React.useState(false);
  const [isLoading, setIsLoading] = React.useState(false);

  useRunOnce(
    () =>
      void getOptions(productPermalink).then(
        (options) => setOptions(option && !options.some(({ id }) => id === option.id) ? [option, ...options] : options),
        (e: unknown) => {
          assertResponseError(e);
          showAlert(e.message, "error");
        },
      ),
  );

  const handleSave = async () => {
    const option = options.find(({ id }) => id === selectedOptionId.value);
    if (!option) return setSelectedOptionId((prev) => ({ ...prev, error: true }));
    try {
      setIsLoading(true);
      await updateOption(purchaseId, option.id, quantity);
      showAlert("Saved variant", "success");
      onChange(option);
      setIsEditing(false);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsLoading(false);
  };

  const title = isSubscription ? "Tier" : "Version";

  return (
    <Card asChild>
      <section>
        <CardContent asChild>
          <header>
            <h3 className="grow">{title}</h3>
          </header>
        </CardContent>
        <CardContent asChild>
          <section>
            {isEditing && options.length > 0 ? (
              <Fieldset state={selectedOptionId.error ? "danger" : undefined} className="grow basis-0">
                <FormSelect
                  value={selectedOptionId.value ?? "None selected"}
                  name={title}
                  onChange={(evt) => setSelectedOptionId({ value: evt.target.value })}
                  aria-invalid={selectedOptionId.error}
                >
                  {!selectedOptionId.value ? <option>None selected</option> : null}
                  {options.map((option) => (
                    <option value={option.id} key={option.id}>
                      {option.name}
                    </option>
                  ))}
                </FormSelect>
                <div className="flex w-full gap-2">
                  <Button onClick={() => setIsEditing(false)} disabled={isLoading} className="flex-1">
                    Cancel
                  </Button>
                  <Button color="primary" onClick={() => void handleSave()} disabled={isLoading} className="flex-1">
                    Save
                  </Button>
                </div>
              </Fieldset>
            ) : (
              <>
                <h5>{option?.name ?? "None selected"}</h5>
                <button className="cursor-pointer underline all-unset" onClick={() => setIsEditing(true)}>
                  Edit
                </button>
              </>
            )}
          </section>
        </CardContent>
      </section>
    </Card>
  );
};

const LicenseSection = ({ license, onSave }: { license: License; onSave: (enabled: boolean) => Promise<void> }) => {
  const [isLoading, setIsLoading] = React.useState(false);

  const handleSave = async (enabled: boolean) => {
    setIsLoading(true);
    await onSave(enabled);
    setIsLoading(false);
  };

  return (
    <Card asChild>
      <section>
        <CardContent asChild>
          <header>
            <h3 className="grow">License key</h3>
          </header>
        </CardContent>
        <CardContent>
          <pre className="grow">
            <code>{license.key}</code>
          </pre>
        </CardContent>
        <CardContent>
          {license.enabled ? (
            <Button color="danger" disabled={isLoading} onClick={() => void handleSave(false)} className="grow basis-0">
              Disable
            </Button>
          ) : (
            <Button disabled={isLoading} onClick={() => void handleSave(true)} className="grow basis-0">
              Enable
            </Button>
          )}
        </CardContent>
      </section>
    </Card>
  );
};

const SeatSection = ({ seats: currentSeats, onSave }: { seats: number; onSave: (seats: number) => Promise<void> }) => {
  const [seats, setSeats] = React.useState(currentSeats);
  const [isEditing, setIsEditing] = React.useState(false);
  const [isLoading, setIsLoading] = React.useState(false);

  const handleSave = async () => {
    setIsLoading(true);
    await onSave(seats);
    setIsLoading(false);
    setIsEditing(false);
  };

  return (
    <Card asChild>
      <section>
        <CardContent asChild>
          <header>
            <h3 className="grow">Seats</h3>
          </header>
        </CardContent>
        {isEditing ? (
          <CardContent asChild>
            <Fieldset>
              <NumberInput value={seats} onChange={(seats) => setSeats(seats ?? 0)}>
                {(props) => <Input type="number" {...props} min={1} aria-label="Seats" className="grow" />}
              </NumberInput>
              <div className="flex w-full gap-2">
                <Button onClick={() => setIsEditing(false)} disabled={isLoading} className="flex-1">
                  Cancel
                </Button>
                <Button color="primary" onClick={() => void handleSave()} disabled={isLoading} className="flex-1">
                  Save
                </Button>
              </div>
            </Fieldset>
          </CardContent>
        ) : (
          <CardContent asChild>
            <section>
              <h5 className="grow font-bold">{seats}</h5>
              <button className="cursor-pointer underline all-unset" onClick={() => setIsEditing(true)}>
                Edit
              </button>
            </section>
          </CardContent>
        )}
      </section>
    </Card>
  );
};

const SubscriptionCancellationSection = ({
  onCancel,
  isInstallmentPlan,
}: {
  onCancel: () => void;
  isInstallmentPlan: boolean;
}) => {
  const [open, setOpen] = React.useState(false);
  const constructor = isInstallmentPlan ? "installment plan" : "subscription";
  return (
    <>
      <Button color="danger" onClick={() => setOpen(true)} className="w-full">
        Cancel {constructor}
      </Button>
      <Modal
        open={open}
        title={`Cancel ${constructor}`}
        onClose={() => setOpen(false)}
        footer={
          <>
            <Button onClick={() => setOpen(false)}>Cancel</Button>
            <Button color="accent" onClick={onCancel}>
              Cancel {constructor}
            </Button>
          </>
        }
      >
        Would you like to cancel this {constructor}?
      </Modal>
    </>
  );
};

const PingButton = ({ purchaseId, className }: { purchaseId: string; className?: string }) => {
  const [isLoading, setIsLoading] = React.useState(false);

  const handleClick = async () => {
    setIsLoading(true);
    try {
      await resendPing(purchaseId);
      showAlert("Ping resent.", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <Button color="primary" disabled={isLoading} onClick={() => void handleClick()} className={className}>
      {isLoading ? "Resending ping..." : "Resend ping"}
    </Button>
  );
};

const AccessSection = ({
  purchaseId,
  isAccessRevoked,
  onChange,
}: {
  purchaseId: string;
  isAccessRevoked: boolean;
  onChange: (accessRevoked: boolean) => void;
}) => {
  const [isLoading, setIsLoading] = React.useState(false);

  const handleClick = async (revoke: boolean) => {
    setIsLoading(true);
    try {
      if (revoke) {
        await revokeAccess(purchaseId);
        showAlert("Access revoked", "success");
        onChange(true);
      } else {
        await undoRevokeAccess(purchaseId);
        showAlert("Access re-enabled", "success");
        onChange(false);
      }
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsLoading(false);
  };

  return isAccessRevoked ? (
    <Button disabled={isLoading} onClick={() => void handleClick(false)} className="w-full">
      Re-enable access
    </Button>
  ) : (
    <Button color="primary" disabled={isLoading} onClick={() => void handleClick(true)} className="w-full">
      Revoke access
    </Button>
  );
};

const RefundForm = ({
  purchaseId,
  currencyType,
  amountRefundable,
  showRefundFeeNotice,
  paypalRefundExpired,
  modalTitle,
  modalText,
  onChange,
  onClose,
  className,
}: {
  purchaseId: string;
  currencyType: CurrencyCode;
  amountRefundable: number;
  showRefundFeeNotice: boolean;
  paypalRefundExpired: boolean;
  modalTitle: string;
  modalText: string;
  onChange: (amountRefundable: number) => void;
  onClose?: () => void;
  className?: string;
}) => {
  const [isLoading, setIsLoading] = React.useState(false);
  const [isModalShowing, setIsModalShowing] = React.useState(false);
  const [refundAmountCents, setRefundAmountCents] = React.useState<{ value: number | null; error?: boolean }>({
    value: amountRefundable,
  });

  const refundAmountRemaining = amountRefundable - (refundAmountCents.value ?? 0);
  const isPartialRefund = refundAmountRemaining > 0;

  const handleRefund = async () => {
    if (!refundAmountCents.value) {
      setIsModalShowing(false);
      return setRefundAmountCents((prev) => ({ ...prev, error: true }));
    }
    try {
      setIsLoading(true);
      await refund(purchaseId, priceCentsToUnit(refundAmountCents.value, getIsSingleUnitCurrency(currencyType)));
      const refundAmountRemaining = amountRefundable - refundAmountCents.value;
      onChange(refundAmountRemaining);
      setRefundAmountCents({ value: refundAmountRemaining });
      showAlert("Purchase successfully refunded.", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsLoading(false);
    setIsModalShowing(false);
  };

  const refundButton = (
    <Button
      color="primary"
      onClick={() => setIsModalShowing(true)}
      disabled={isLoading || paypalRefundExpired}
      className="w-full"
    >
      {isLoading ? "Refunding..." : isPartialRefund ? "Issue partial refund" : "Refund fully"}
    </Button>
  );

  return (
    <>
      <Fieldset state={refundAmountCents.error ? "danger" : undefined} className={className}>
        <PriceInput
          cents={refundAmountCents.value}
          onChange={(value) => setRefundAmountCents({ value })}
          currencyCode={currencyType}
          placeholder={formatPriceCentsWithoutCurrencySymbol(currencyType, amountRefundable)}
          hasError={refundAmountCents.error ?? false}
        />
        <div className="flex w-full gap-2">
          {onClose ? (
            <Button onClick={onClose} disabled={isLoading} className="flex-1">
              Cancel
            </Button>
          ) : null}
          <div className="flex-1">
            {paypalRefundExpired ? (
              <WithTooltip tip="PayPal refunds aren't available after 6 months." position="top">
                {refundButton}
              </WithTooltip>
            ) : (
              refundButton
            )}
          </div>
        </div>
        {showRefundFeeNotice ? (
          <Alert role="status" variant="info">
            Going forward, Gumroad does not return any fees when a payment is refunded.{" "}
            <a href="/help/article/47-how-to-refund-a-customer" target="_blank" rel="noreferrer">
              Learn more
            </a>
          </Alert>
        ) : null}
      </Fieldset>
      <div style={{ display: "contents" }}>
        <Modal
          open={isModalShowing}
          onClose={() => setIsModalShowing(false)}
          title={modalTitle}
          footer={
            <>
              <Button onClick={() => setIsModalShowing(false)} disabled={isLoading}>
                Cancel
              </Button>
              <Button color="accent" onClick={() => void handleRefund()} disabled={isLoading}>
                {isLoading ? "Refunding..." : "Confirm refund"}
              </Button>
            </>
          }
        >
          {modalText}
        </Modal>
      </div>
    </>
  );
};

const ChargeRow = ({
  purchase,
  customerEmail,
  onChange,
  showRefundFeeNotice,
  canPing,
  className,
}: {
  purchase: Charge;
  customerEmail: string;
  onChange: (update: Partial<Charge>) => void;
  showRefundFeeNotice: boolean;
  canPing: boolean;
  className?: string;
}) => {
  const [isRefunding, setIsRefunding] = React.useState(false);
  const userAgentInfo = useUserAgentInfo();
  const currentSeller = useCurrentSeller();

  return (
    <div className={className}>
      <div className="flex items-center justify-between gap-4">
        <div className="flex items-center gap-2">
          <h5>
            {formatPrice(purchase.amount_refundable, purchase.currency_type)} on{" "}
            {new Date(purchase.created_at).toLocaleDateString(userAgentInfo.locale, {
              year: "numeric",
              month: "numeric",
              day: "numeric",
              timeZone: currentSeller?.timeZone.name,
            })}
          </h5>
          <a
            href={
              purchase.transaction_url_for_seller ?? Routes.receipt_purchase_path(purchase.id, { email: customerEmail })
            }
            target="_blank"
            rel="noreferrer"
            aria-label="Transaction"
          >
            <ArrowUpRightSquare className="size-5" />
          </a>
          {purchase.partially_refunded ? (
            <Pill size="small">Partial refund</Pill>
          ) : purchase.refunded ? (
            <Pill size="small">Refunded</Pill>
          ) : null}
          {purchase.is_upgrade_purchase ? (
            <WithTooltip tip="This is an upgrade charge, generated when the subscriber upgraded to a more expensive plan.">
              <Pill size="small">Upgrade</Pill>
            </WithTooltip>
          ) : null}
          {purchase.chargedback ? <Pill size="small">Chargedback</Pill> : null}
        </div>
        <div className="flex items-center gap-2">
          {canPing ? <PingButton purchaseId={purchase.id} /> : null}
          {!purchase.refunded && !purchase.chargedback && purchase.amount_refundable > 0 ? (
            <button
              className="cursor-pointer text-sm underline all-unset"
              onClick={() => setIsRefunding((prev) => !prev)}
            >
              Refund Options
            </button>
          ) : null}
        </div>
      </div>
      {isRefunding ? (
        <div className="mt-3">
          <RefundForm
            purchaseId={purchase.id}
            currencyType={purchase.currency_type}
            amountRefundable={purchase.amount_refundable}
            showRefundFeeNotice={showRefundFeeNotice}
            paypalRefundExpired={purchase.paypal_refund_expired}
            modalTitle="Charge refund"
            modalText="Would you like to confirm this charge refund?"
            onChange={(amountRefundable) => {
              onChange({
                amount_refundable: amountRefundable,
                refunded: amountRefundable === 0,
                partially_refunded: amountRefundable > 0 && amountRefundable < purchase.amount_refundable,
              });
              setIsRefunding(false);
            }}
            onClose={() => setIsRefunding(false)}
          />
        </div>
      ) : null}
    </div>
  );
};

const ChargesSection = ({
  charges,
  remainingCharges,
  onChange,
  showRefundFeeNotice,
  canPing,
  customerEmail,
  loading,
}: {
  charges: Charge[];
  remainingCharges: number | null;
  onChange: (charges: Charge[]) => void;
  showRefundFeeNotice: boolean;
  canPing: boolean;
  customerEmail: string;
  loading: boolean;
}) => {
  const updateCharge = (id: string, update: Partial<Charge>) =>
    onChange(charges.map((charge) => (charge.id === id ? { ...charge, ...update } : charge)));

  return (
    <Card asChild>
      <section>
        <CardContent asChild>
          <header>
            <h3 className="grow">Charges</h3>
          </header>
        </CardContent>
        {loading ? (
          <CardContent>
            <div className="grow text-center">
              <LoadingSpinner className="size-8" />
            </div>
          </CardContent>
        ) : charges.length > 0 ? (
          <>
            {remainingCharges !== null ? (
              <CardContent>
                <Alert role="status" variant="info">
                  {`${remainingCharges} ${remainingCharges > 1 ? "charges" : "charge"} remaining`}
                </Alert>
              </CardContent>
            ) : null}
            {charges.map((charge) => (
              <CardContent asChild key={charge.id}>
                <section>
                  <ChargeRow
                    purchase={charge}
                    customerEmail={customerEmail}
                    onChange={(update) => updateCharge(charge.id, update)}
                    showRefundFeeNotice={showRefundFeeNotice}
                    canPing={canPing}
                  />
                </section>
              </CardContent>
            ))}
          </>
        ) : (
          <CardContent>
            <p className="text-muted">No charges yet</p>
          </CardContent>
        )}
      </section>
    </Card>
  );
};

const CallSection = ({ call, onChange }: { call: Call; onChange: (call: Call) => void }) => {
  const currentSeller = useCurrentSeller();
  const [isLoading, setIsLoading] = React.useState(false);
  const [callUrl, setCallUrl] = React.useState(call.call_url ?? "");
  const handleSave = async () => {
    setIsLoading(true);
    try {
      await updateCallUrl(call.id, callUrl);
      onChange({ ...call, call_url: callUrl });
      showAlert("Call URL updated!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsLoading(false);
  };

  return (
    <Card asChild>
      <section>
        <CardContent asChild>
          <header>
            <h3 className="grow">Call</h3>
          </header>
        </CardContent>
        <CardContent>
          <DefinitionList>
            <dt>Start time</dt>
            <dd>
              {formatCallDate(new Date(call.start_time), { timeZone: { userTimeZone: currentSeller?.timeZone.name } })}
            </dd>
            <dt>End time</dt>
            <dd>
              {formatCallDate(new Date(call.end_time), { timeZone: { userTimeZone: currentSeller?.timeZone.name } })}
            </dd>
          </DefinitionList>
        </CardContent>
        <CardContent>
          <form
            onSubmit={(evt) => {
              evt.preventDefault();
              void handleSave();
            }}
            className="w-full"
          >
            <Fieldset>
              <Input
                type="text"
                value={callUrl}
                onChange={(evt) => setCallUrl(evt.target.value)}
                placeholder="Call URL"
              />
              <Button color="primary" type="submit" disabled={isLoading} className="w-full">
                {isLoading ? "Saving..." : "Save"}
              </Button>
            </Fieldset>
          </form>
        </CardContent>
      </section>
    </Card>
  );
};

const FileRow = ({ file, disabled, onDelete }: { file: File; disabled?: boolean; onDelete?: () => void }) => (
  <Row role="listitem">
    <RowContent>
      <FileKindIcon extension={file.extension} />
      <div>
        <h4>{file.name}</h4>
        <InlineList>
          <li>{file.extension}</li>
          <li>{FileUtils.getFullFileSizeString(file.size)}</li>
        </InlineList>
      </div>
    </RowContent>
    <RowActions>
      {onDelete ? (
        <Button color="danger" size="icon" onClick={onDelete} disabled={disabled} aria-label="Delete">
          <Trash className="size-5" />
        </Button>
      ) : null}
      <NavigationButton
        size="icon"
        href={Routes.s3_utility_cdn_url_for_blob_path({ key: file.key })}
        download
        target="_blank"
        disabled={disabled}
        aria-label="Download"
      >
        <ArrowDown pack="filled" className="size-5" />
      </NavigationButton>
    </RowActions>
  </Row>
);

const CommissionSection = ({
  commission,
  onChange,
}: {
  commission: Commission;
  onChange: (commission: Commission) => void;
}) => {
  const [isLoading, setIsLoading] = React.useState(false);

  const handleFileChange = asyncVoid(async (event: React.ChangeEvent<HTMLInputElement>) => {
    if (!event.target.files?.length) return;

    setIsLoading(true);

    try {
      const filesToUpload = Array.from(event.target.files);

      const blobs = await Promise.all(
        filesToUpload.map(
          (file) =>
            new Promise<Blob>((resolve, reject) => {
              new DirectUpload(file, Routes.rails_direct_uploads_path()).create((error, blob) => {
                if (error) reject(error);
                else resolve(blob);
              });
            }),
        ),
      );

      await updateCommission(commission.id, [
        ...commission.files.map(({ id }) => id),
        ...blobs.map(({ signed_id }) => signed_id),
      ]);

      onChange({
        ...commission,
        files: [
          ...commission.files,
          ...filesToUpload.map((file, index) => ({
            id: blobs[index]?.signed_id ?? "",
            name: FileUtils.getFileNameWithoutExtension(file.name),
            size: file.size,
            extension: FileUtils.getFileExtension(file.name).toUpperCase(),
            key: blobs[index]?.key ?? "",
          })),
        ],
      });

      showAlert("Uploaded successfully!", "success");
    } catch {
      showAlert("Error uploading files. Please try again.", "error");
    } finally {
      setIsLoading(false);
    }
  });

  const handleDelete = async (fileId: string) => {
    try {
      setIsLoading(true);
      await updateCommission(
        commission.id,
        commission.files.filter(({ id }) => id !== fileId).map(({ id }) => id),
      );
      onChange({
        ...commission,
        files: commission.files.filter(({ id }) => id !== fileId),
      });
      showAlert("File deleted successfully!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setIsLoading(false);
    }
  };

  const handleCompletion = async () => {
    try {
      setIsLoading(true);
      await completeCommission(commission.id);
      onChange({ ...commission, status: "completed" });
      showAlert("Commission completed!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <Card asChild>
      <section>
        <CardContent asChild>
          <header>
            <h3 className="grow">Files</h3>
          </header>
        </CardContent>
        {commission.files.length ? (
          <CardContent>
            <Rows role="list">
              {commission.files.map((file) => (
                <FileRow key={file.id} file={file} onDelete={() => void handleDelete(file.id)} disabled={isLoading} />
              ))}
            </Rows>
          </CardContent>
        ) : null}
        <CardContent>
          <div className="grid w-full gap-2">
            <label className={buttonVariants({ className: "w-full" })}>
              <input
                type="file"
                onChange={handleFileChange}
                disabled={isLoading}
                multiple
                style={{ display: "none" }}
              />
              <Paperclip className="size-5" /> Upload files
            </label>
            {commission.status === "in_progress" ? (
              <Button color="primary" disabled={isLoading} onClick={() => void handleCompletion()} className="w-full">
                Submit and mark as complete
              </Button>
            ) : null}
          </div>
        </CardContent>
      </section>
    </Card>
  );
};

const BREAKPOINT_MD = 768;
const BREAKPOINT_LG = 1024;

const ColumnLayout = ({ children, className }: { children: React.ReactNode; className?: string }) => {
  const [columnCount, setColumnCount] = React.useState(() => {
    if (typeof window === "undefined") return 1;
    if (window.innerWidth >= BREAKPOINT_LG) return 3;
    if (window.innerWidth >= BREAKPOINT_MD) return 2;
    return 1;
  });

  React.useEffect(() => {
    const updateColumns = () => {
      const newCount = window.innerWidth >= BREAKPOINT_LG ? 3 : window.innerWidth >= BREAKPOINT_MD ? 2 : 1;
      setColumnCount((prev) => {
        if (prev !== newCount) setColumnAssignments(null);
        return newCount;
      });
    };
    window.addEventListener("resize", updateColumns);
    return () => window.removeEventListener("resize", updateColumns);
  }, []);

  const items = React.Children.toArray(children).filter(Boolean);
  const measureRef = React.useRef<HTMLDivElement>(null);
  const [columnAssignments, setColumnAssignments] = React.useState<number[] | null>(null);

  React.useLayoutEffect(() => {
    if (columnCount <= 1 || !measureRef.current) {
      setColumnAssignments(null);
      return;
    }

    const actualColumns = Math.min(columnCount, items.length);
    const assignments: number[] = [];
    const childElements = measureRef.current.children;

    let totalHeight = 0;
    for (const child of childElements) {
      totalHeight += child instanceof HTMLElement ? child.offsetHeight : 0;
    }
    const targetPerColumn = totalHeight / actualColumns;

    let currentColumn = 0;
    let currentHeight = 0;
    for (const child of childElements) {
      const itemHeight = child instanceof HTMLElement ? child.offsetHeight : 0;
      if (currentColumn < actualColumns - 1 && currentHeight > 0 && currentHeight + itemHeight / 2 > targetPerColumn) {
        currentColumn++;
        currentHeight = 0;
      }
      assignments.push(currentColumn);
      currentHeight += itemHeight;
    }

    setColumnAssignments(assignments);
  }, [columnCount, items.length]);

  if (columnCount === 1) {
    return <div className={className}>{items}</div>;
  }

  if (columnAssignments === null) {
    return (
      <div ref={measureRef} className={className}>
        {items}
      </div>
    );
  }

  const actualColumns = Math.min(columnCount, items.length);
  const columns: React.ReactNode[][] = Array.from({ length: actualColumns }, () => []);
  items.forEach((item, i) => {
    const col = columnAssignments[i] ?? 0;
    columns[col]?.push(item);
  });

  return (
    <div
      className={className}
      style={{ display: "grid", gridTemplateColumns: `repeat(${actualColumns}, 1fr)`, gap: "2rem" }}
    >
      {columns.map((col, i) => (
        <div key={i} className="flex flex-col gap-8">
          {col}
        </div>
      ))}
    </div>
  );
};

export default CustomerDetailPage;
