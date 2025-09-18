import { differenceInYears, parseISO } from "date-fns";
import * as React from "react";

import { addPurchaseToLibrary } from "$app/data/account";
import { deletePurchasedProduct } from "$app/data/library";
import { signupAndAddPurchaseToLibrary } from "$app/data/open_in_app";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Modal } from "$app/components/Modal";
import { PurchaseArchiveButton } from "$app/components/PurchaseArchiveButton";
import { Review, ReviewForm } from "$app/components/ReviewForm";
import { showAlert } from "$app/components/server-components/Alert";
import { PurchaseCustomField } from "$app/components/server-components/DownloadPage/WithContent";
import { PageHeader } from "$app/components/ui/PageHeader";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";

type ContentUnavailabilityReasonCode =
  | "inactive_membership"
  | "rental_expired"
  | "access_expired"
  | "email_confirmation_required"
  | null;
type Call = { start_time: string; end_time: string; url: string | null };

export type LayoutProps = {
  content_unavailability_reason_code: ContentUnavailabilityReasonCode;
  is_mobile_app_web_view: boolean;
  terms_page_url: string;
  token: string;
  redirect_id: string;
  creator: { name: string; profile_url: string; avatar_url: string | null } | null;
  add_to_library_option: AddToLibraryOption;
  installment: { name: string } | null;
  purchase: {
    id: string;
    bundle_purchase_id: string | null;
    email: string | null;
    email_digest: string;
    is_archived: boolean;
    product_id: string | null;
    product_permalink: string | null;
    product_name: string | null;
    variant_id: string | null;
    variant_name: string | null;
    product_long_url: string | null;
    created_at: string;
    allows_review: boolean;
    disable_reviews_after_year: boolean;
    review: Review | null;
    membership: {
      has_active_subscription: boolean;
      subscription_id: string;
      is_subscription_ended: boolean | null;
      is_subscription_cancelled_or_failed: boolean | null;
      is_alive_or_restartable: boolean | null;
      in_free_trial: boolean;
      is_installment_plan: boolean;
    } | null;
    purchase_custom_fields: PurchaseCustomField[];
    call: Call | null;
  } | null;
};

export const Layout = ({
  content_unavailability_reason_code,
  is_mobile_app_web_view,
  purchase,
  installment,
  terms_page_url,
  add_to_library_option,
  creator,
  headerActions,
  pageList,
  children,
}: LayoutProps & { headerActions?: React.ReactNode; pageList?: React.ReactNode; children: React.ReactNode }) => {
  const loggedInUser = useLoggedInUser();
  const [isResendingReceipt, setIsResendingReceipt] = React.useState(false);
  const isDesktop = useIsAboveBreakpoint("lg");
  const [headerVisible, setHeaderVisible] = React.useState(true);
  const headerRef = React.useRef<HTMLDivElement | null>(null);

  React.useEffect(() => {
    const observer = new IntersectionObserver((entries) => setHeaderVisible(entries[0]?.isIntersecting ?? false));

    if (headerRef.current) observer.observe(headerRef.current);

    return () => observer.disconnect();
  }, [headerRef.current]);

  const handleResendReceipt = asyncVoid(async (purchaseId: string) => {
    setIsResendingReceipt(true);
    try {
      await request({
        method: "POST",
        url: Routes.resend_receipt_purchase_path(purchaseId),
        accept: "json",
      });
      showAlert("Receipt resent", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert("Sorry, something went wrong. Please try again.", "error");
    }
    setIsResendingReceipt(false);
  });

  const receiptPurchaseId = purchase?.bundle_purchase_id ?? purchase?.id;

  const disabledStatus =
    purchase && differenceInYears(new Date(), parseISO(purchase.created_at)) >= 1 && purchase.disable_reviews_after_year
      ? "Reviews may not be created or modified for this product 1 year after purchase."
      : purchase?.membership?.in_free_trial
        ? "Reviews are not allowed during the free trial period."
        : null;

  const settings = is_mobile_app_web_view ? null : (
    <>
      {content_unavailability_reason_code !== "email_confirmation_required" ? (
        <>
          {(purchase?.allows_review || disabledStatus) && purchase?.product_permalink ? (
            <div className="stack">
              <ReviewForm
                permalink={purchase.product_permalink}
                purchaseId={purchase.id}
                purchaseEmailDigest={purchase.email_digest}
                review={purchase.review}
                disabledStatus={disabledStatus}
              />
            </div>
          ) : null}
          {purchase?.email ? (
            <AddToLibrary
              add_to_library_option={add_to_library_option}
              terms_page_url={terms_page_url}
              purchase_id={purchase.id}
              purchase_email={purchase.email}
            />
          ) : null}
          {purchase ? (
            <div className="stack">
              {content_unavailability_reason_code === null && purchase.membership ? (
                purchase.membership.is_installment_plan ? (
                  <details>
                    <summary>Installment plan</summary>
                    {purchase.membership.is_subscription_ended ? (
                      "This installment plan has been paid in full."
                    ) : (
                      <NavigationButton href={Routes.manage_subscription_url(purchase.membership.subscription_id)}>
                        Manage
                      </NavigationButton>
                    )}
                  </details>
                ) : (
                  <details>
                    <summary>Membership</summary>
                    <div style={{ display: "grid" }}>
                      {purchase.membership.has_active_subscription ? (
                        <NavigationButton href={Routes.manage_subscription_url(purchase.membership.subscription_id)}>
                          Manage
                        </NavigationButton>
                      ) : purchase.membership.is_subscription_ended ? (
                        "This subscription has ended."
                      ) : purchase.membership.is_subscription_cancelled_or_failed ? (
                        <NavigationButton href={Routes.manage_subscription_url(purchase.membership.subscription_id)}>
                          Restart
                        </NavigationButton>
                      ) : null}
                    </div>
                  </details>
                )
              ) : null}
              {receiptPurchaseId ? (
                <details>
                  <summary>Receipt</summary>
                  <div className="paragraphs">
                    <NavigationButton
                      href={
                        purchase.email
                          ? Routes.receipt_purchase_url(receiptPurchaseId, { email: purchase.email })
                          : Routes.receipt_purchase_url(receiptPurchaseId)
                      }
                    >
                      View receipt
                    </NavigationButton>
                    <Button onClick={() => handleResendReceipt(receiptPurchaseId)} disabled={isResendingReceipt}>
                      {isResendingReceipt ? "Resending receipt..." : "Resend receipt"}
                    </Button>
                  </div>
                </details>
              ) : null}
              {loggedInUser !== null ? (
                <details>
                  <summary>Library</summary>
                  <div className="paragraphs">
                    <PurchaseArchiveButton purchase_id={purchase.id} initial_is_archived={purchase.is_archived} />
                    <PurchaseDeleteButton purchase_id={purchase.id} product_name={purchase.product_name} />
                  </div>
                </details>
              ) : null}
            </div>
          ) : null}
        </>
      ) : null}
      {purchase?.call ? <CallDetails call={purchase.call} /> : null}
      <EntityInfo
        entityName={
          purchase
            ? purchase.product_name
              ? purchase.variant_name
                ? `${purchase.product_name} - ${purchase.variant_name}`
                : purchase.product_name
              : null
            : installment
              ? installment.name
              : null
        }
        creator={creator}
      />
    </>
  );

  return (
    <>
      {loggedInUser && !is_mobile_app_web_view ? (
        <div className="font-size-base grid-row-[-3] text-singleline border-b border-border px-8 py-4">
          <a style={{ textDecoration: "none" }} href={Routes.library_url()} title="Back to Library">
            <Icon name="arrow-left" className="mr-1.5" />
            {headerVisible ? "Back to Library" : null}
          </a>
          {!headerVisible ? <strong>{purchase?.product_name}</strong> : null}
        </div>
      ) : null}
      <div className="product-content flex-1">
        {is_mobile_app_web_view ? null : (
          <PageHeader ref={headerRef} title={purchase?.product_name ?? ""} actions={headerActions} />
        )}
        {settings || pageList ? (
          <div className="has-sidebar p-4 md:p-8">
            <div className="paragraphs">
              {pageList}
              {isDesktop ? settings : null}
            </div>
            <div className="paragraphs">
              {children}
              {!isDesktop ? settings : null}
            </div>
          </div>
        ) : (
          <div className="paragraphs flex-1 p-4 md:p-8">{children}</div>
        )}
      </div>
    </>
  );
};

const CallDetails = ({ call }: { call: Call }) => {
  const startTime = new Date(call.start_time);
  const endTime = new Date(call.end_time);
  const formatTime = (date: Date) =>
    date.toLocaleTimeString("en-US", {
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    });

  const formatDate = (date: Date) =>
    date.toLocaleDateString("en-US", {
      weekday: "long",
      year: "numeric",
      month: "long",
      day: "numeric",
    });

  const formattedStartDate = formatDate(startTime);
  const formattedEndDate = formatDate(endTime);

  return (
    <div className="stack">
      <div>
        <h5>
          {`${formatTime(startTime)} - ${formatTime(endTime)} ${
            Intl.DateTimeFormat("en-US", { timeZoneName: "short" })
              .formatToParts(new Date())
              .find((part) => part.type === "timeZoneName")?.value ?? ""
          }`}
        </h5>
        {formattedStartDate === formattedEndDate ? formattedStartDate : `${formattedStartDate} - ${formattedEndDate}`}
      </div>
      {call.url ? (
        <div>
          <strong>Call link</strong>
          <a href={call.url} target="_blank" rel="noopener noreferrer">
            {call.url}
          </a>
        </div>
      ) : null}
    </div>
  );
};

export const EntityInfo = ({ entityName, creator }: { entityName: string | null; creator: LayoutProps["creator"] }) =>
  entityName || creator ? (
    <div className="stack">
      {entityName ? <div>{entityName}</div> : null}
      {creator ? (
        <div>
          <span style={{ display: "flex", alignItems: "center", gap: "var(--spacer-2)" }}>
            {creator.avatar_url ? <img className="user-avatar" src={creator.avatar_url} /> : null}

            <span>
              By{" "}
              <a href={creator.profile_url} target="_blank" style={{ position: "relative" }} rel="noreferrer">
                {creator.name}
              </a>
            </span>
          </span>
        </div>
      ) : null}
    </div>
  ) : null;

const PurchaseDeleteButton = ({
  purchase_id,
  product_name,
}: {
  purchase_id: string;
  product_name: string | null;
  small?: boolean;
}) => {
  const [isDeleteModalOpen, setIsDeleteModalOpen] = React.useState(false);
  const [isDeleting, setIsDeleting] = React.useState(false);

  const handleDelete = asyncVoid(async () => {
    setIsDeleting(true);
    try {
      await deletePurchasedProduct({ purchase_id });
      showAlert("Product deleted!", "success");
      window.location.href = Routes.library_path();
    } catch (e) {
      assertResponseError(e);
      showAlert("Something went wrong.", "error");
    }
    setIsDeleting(false);
  });

  return (
    <>
      <Button color="danger" onClick={() => setIsDeleteModalOpen(true)}>
        Delete permanently
      </Button>
      <Modal
        open={isDeleteModalOpen}
        onClose={() => setIsDeleteModalOpen(false)}
        title="Delete Product"
        footer={
          <>
            <Button onClick={() => setIsDeleteModalOpen(false)}>Cancel</Button>
            <Button color="danger" onClick={handleDelete}>
              {isDeleting ? "Deleting..." : "Confirm"}
            </Button>
          </>
        }
      >
        <>
          Are you sure you want to delete <b>{product_name ?? ""}</b>?
        </>
      </Modal>
    </>
  );
};

type AddToLibraryOption = "none" | "add_to_library_button" | "signup_form";
type AddToLibraryProps = {
  add_to_library_option: AddToLibraryOption;
  terms_page_url: string;
  purchase_id: string;
  purchase_email: string;
};
const AddToLibrary = ({ add_to_library_option, terms_page_url, purchase_id, purchase_email }: AddToLibraryProps) => {
  const [password, setPassword] = React.useState("");
  const [isSubmitting, setIsSubmitting] = React.useState(false);

  const handleAddPurchaseToLibrary = asyncVoid(async () => {
    setIsSubmitting(true);
    try {
      const result = await addPurchaseToLibrary({ purchaseId: purchase_id, purchaseEmail: purchase_email });
      window.location.href = result.redirectLocation;
    } catch (error) {
      assertResponseError(error);
      showAlert("Sorry, something went wrong. Please try again.", "error");
    }
    setIsSubmitting(false);
  });

  const handleSignupAndAddPurchaseToLibrary = asyncVoid(async (event: React.FormEvent) => {
    event.preventDefault();

    setIsSubmitting(true);
    try {
      await signupAndAddPurchaseToLibrary({
        purchaseId: purchase_id,
        buyerSignup: true,
        termsAccepted: true,
        email: purchase_email,
        password,
      });
      window.location.href = Routes.library_path();
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error");
    }
    setIsSubmitting(false);
  });

  if (add_to_library_option === "none") return null;

  return (
    <div className="stack">
      {add_to_library_option === "add_to_library_button" ? (
        <>
          <span>Access this product from anywhere, forever:</span>
          <div>
            <div style={{ display: "grid" }}>
              <Button color="primary" onClick={handleAddPurchaseToLibrary} disabled={isSubmitting}>
                {isSubmitting ? "Adding..." : "Add to library"}
              </Button>
            </div>
          </div>
        </>
      ) : (
        <>
          <span>Create an account to access all of your purchases in one place</span>
          <div>
            <form
              autoComplete="off"
              onSubmit={handleSignupAndAddPurchaseToLibrary}
              style={{ display: "grid", gap: "var(--spacer-4)" }}
            >
              <fieldset>
                <input
                  type="password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="Your password"
                />
                <small>
                  You agree to our <a href={terms_page_url}>Terms Of Use</a>.
                </small>
              </fieldset>
              <Button color="primary" type="submit" disabled={isSubmitting}>
                {isSubmitting ? "Creating..." : "Create"}
              </Button>
            </form>
          </div>
        </>
      )}
    </div>
  );
};
