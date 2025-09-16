import * as React from "react";

import { createAccount, CreateAccountPayload } from "$app/data/account";
import { ErrorLineItemResult, LineItemResult, SuccessfulLineItemResult } from "$app/data/purchase";
import { trackUserProductAction } from "$app/data/user_action_event";
import { assertResponseError } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import { CartItem } from "$app/components/Checkout/cartState";
import { useState } from "$app/components/Checkout/payment";
import { DiscordButton } from "$app/components/DiscordButton";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { showAlert } from "$app/components/server-components/Alert";

export const LineItem = ({
  name,
  price,
  quantity,
}: {
  name: string;
  price?: string | undefined;
  quantity?: number | undefined;
}) => (
  <>
    <h4 className="product-details">
      <div className="product-name">
        {name}
        {quantity ? <span className="quantity">× {quantity}</span> : null}
      </div>
    </h4>
    {price ? <div className="receipt-price">{price}</div> : null}
  </>
);

export const LineItemResultEntry = ({ name, result }: { name: string; result: LineItemResult }) =>
  result.success ? (
    <SuccessfulLineItemResultEntry name={name} result={result} />
  ) : (
    <FailedLineItemResultEntry name={name} result={result} />
  );

const FailedLineItemResultEntry = ({ name, result }: { name: string; result: ErrorLineItemResult }) => {
  const message = result.error_message ?? "Sorry, something went wrong.";
  return (
    <>
      <div>
        <section className="stack borderless">
          <div>
            <LineItem
              name={name}
              price={"formatted_price" in result ? (result.formatted_price ?? undefined) : undefined}
            />
          </div>
        </section>
      </div>
      <div>
        <div
          className="payment_failed_notice warning"
          role="alert"
          dangerouslySetInnerHTML={{ __html: `<div>${message}</div>` }}
        />
      </div>
    </>
  );
};

const SuccessfulLineItemResultEntry = ({ name, result }: { name: string; result: SuccessfulLineItemResult }) => {
  // TODO only do this for a logged-in user
  const trackViewContentClick = () => {
    void trackUserProductAction({
      name: "receipt_view_content",
      permalink: result.permalink,
    });
  };

  return (
    <>
      <div>
        <section className="stack borderless">
          <div>
            <LineItem
              name={`${name} ${result.variants_displayable}`}
              quantity={result.show_quantity ? result.quantity : undefined}
              price={result.price}
            />
          </div>
          {result.enabled_integrations.discord ? (
            <div>
              <DiscordButton
                purchaseId={result.id}
                connected={false}
                redirectSettings={{ host: result.domain, protocol: result.protocol }}
                customState={JSON.stringify({
                  seller_id: result.seller_id,
                  is_custom_domain: !window.location.hostname.endsWith(result.domain.replace("app.", "")),
                })}
              />
            </div>
          ) : null}
          {result.content_url ? (
            <div>
              <NavigationButton
                href={result.content_url}
                color="accent"
                target="_blank"
                onClick={trackViewContentClick}
              >
                {result.view_content_button_text}
              </NavigationButton>
            </div>
          ) : null}
          {result.is_gift_sender_purchase ? (
            <div>
              <div className="text-muted">
                {result.gift_sender_text}
                {result.has_files
                  ? "They'll get an email with your note and a download link."
                  : "They'll get an email with your note."}
              </div>
            </div>
          ) : result.extra_purchase_notice ? (
            <div>
              <div className="text-muted">{result.extra_purchase_notice}</div>
            </div>
          ) : null}
          {result.is_gift_receiver_purchase ? (
            <div>
              <div className="text-muted">{result.gift_receiver_text}</div>
            </div>
          ) : null}
          {result.test_purchase_notice ? (
            <div>
              <div className="text-muted">{result.test_purchase_notice}</div>
            </div>
          ) : null}
          <div>
            <div className="generate-invoice text-muted">
              Need an invoice for this?{" "}
              <a
                target="_blank"
                href={Routes.generate_invoice_by_buyer_path(result.id, { email: result.email })}
                rel="noreferrer"
              >
                Generate
              </a>
            </div>
          </div>
        </section>
      </div>

      {result.has_shipping_to_show ? (
        <div>
          <section className="stack borderless">
            <div>
              <LineItem name="Shipping" price={result.shipping_amount} />
            </div>
          </section>
        </div>
      ) : null}

      {result.has_sales_tax_to_show ? (
        <div>
          <section className="stack borderless">
            <div>
              <LineItem name={result.sales_tax_label ?? ""} price={result.sales_tax_amount} />
            </div>
          </section>
        </div>
      ) : null}
    </>
  );
};

export const CreateAccountForm = ({
  createAccountData,
}: {
  createAccountData: Pick<CreateAccountPayload, "email" | "cardParams" | "purchaseId">;
}) => {
  const [password, setPassword] = React.useState("");
  const [status, setStatus] = React.useState<"idle" | "processing" | "success">("idle");

  const startAccountCreation = async () => {
    setStatus("processing");

    try {
      await createAccount({
        ...createAccountData,
        buyerSignup: true,
        password,
        termsAccepted: true,
      });
      setStatus("success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
      setStatus("idle");
    }
  };

  const uid = React.useId();

  return (
    <form
      onSubmit={(evt) => {
        evt.preventDefault();
        void startAccountCreation();
      }}
      className="paragraphs"
    >
      {status === "success" ? (
        <div className="success" role="alert">
          Done! Your account has been created. You'll get a confirmation email shortly.
        </div>
      ) : (
        <>
          <div>
            <h3>Create an account to access all of your purchases in one place</h3>
          </div>
          <fieldset>
            <legend>
              <label htmlFor={`${uid}email`}>Email</label>
            </legend>
            <input type="text" readOnly value={createAccountData.email} id={`${uid}email`} />
          </fieldset>
          <fieldset>
            <legend>
              <label htmlFor={`${uid}password`}>Password</label>
            </legend>
            <input
              type="password"
              placeholder="Enter password"
              value={password}
              onChange={(evt) => setPassword(evt.target.value)}
              id={`${uid}password`}
            />
            <small>
              You agree to our <a href="https://gumroad.com/terms">Terms Of Use</a>.
            </small>
          </fieldset>

          <Button type="submit" color="primary" disabled={status === "processing"}>
            {status === "processing" ? "..." : "Sign up"}
          </Button>
        </>
      )}
    </form>
  );
};

type PurchaseResults = { item: CartItem; result: LineItemResult }[];

export const Receipt = ({
  results,
  discoverUrl,
  canBuyerSignUp,
}: {
  results: PurchaseResults;
  discoverUrl: string;
  canBuyerSignUp: boolean;
}) => {
  const user = useLoggedInUser();
  const [state] = useState();
  if (state.status.type !== "finished") return null;
  return (
    <div className="stack mx-auto my-8 max-w-2xl">
      <header>
        <h4 style={{ position: "relative" }}>
          Checkout
          <a href={discoverUrl} style={{ position: "absolute", right: 0 }} aria-label="Close">
            <Icon name="x-circle" />
          </a>
        </h4>
      </header>
      <header>
        <h2>{results.some(({ result }) => !result.success) ? "Summary" : "Your purchase was successful!"}</h2>

        {results.some(({ result }) => result.success) ? (
          <div>
            {results.some(
              ({ result, item }) =>
                result.success &&
                result.non_formatted_price > 0 &&
                !item.product.is_preorder &&
                !item.product.free_trial,
            )
              ? `We charged your card and sent a receipt to ${state.email}`
              : `We sent a receipt to ${state.email}`}
          </div>
        ) : null}
      </header>
      {results.map(({ result, item }, key) => (
        <LineItemResultEntry key={key} result={result} name={item.product.name} />
      ))}
      {!user && canBuyerSignUp ? (
        <CreateAccountForm
          createAccountData={{
            email: state.email,
            cardParams:
              state.status.paymentMethod.type === "not-applicable" || state.status.paymentMethod.type === "saved"
                ? null
                : state.status.paymentMethod.cardParamsResult.cardParams,
          }}
        />
      ) : null}
    </div>
  );
};
