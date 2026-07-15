import { XCircle } from "@boxicons/react";
import * as React from "react";

import { createAccount, CreateAccountPayload } from "$app/data/account";
import type { ErrorLineItemResult, LineItemResult, SuccessfulLineItemResult } from "$app/data/purchase";
import { trackUserProductAction } from "$app/data/user_action_event";
import { classNames } from "$app/utils/classNames";
import { assertResponseError } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import { CartItem } from "$app/components/Checkout/cartState";
import { useState } from "$app/components/Checkout/payment";
import { DiscordButton } from "$app/components/DiscordButton";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Card, CardContent } from "$app/components/ui/Card";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";

export const LineItem = ({
  name,
  price,
  quantity,
  card,
}: {
  name: string;
  price?: string | undefined;
  quantity?: number | undefined;
  card?: boolean;
}) => (
  <>
    {/* h3 keeps the document outline monotonic: the card's section heading is an h2. */}
    <h3 className={classNames("product-details", card ? "grow font-bold" : "")}>
      <div className="product-name">
        {name}
        {quantity ? <span className="quantity">× {quantity}</span> : null}
      </div>
    </h3>
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
    <CardContent asChild details>
      <section className="space-y-3">
        <div className="flex flex-wrap items-center justify-between gap-4">
          <LineItem
            name={name}
            price={"formatted_price" in result ? (result.formatted_price ?? undefined) : undefined}
            card
          />
        </div>
        <Alert variant="warning">
          <div dangerouslySetInnerHTML={{ __html: message }} />
        </Alert>
      </section>
    </CardContent>
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
      <CardContent>
        {/* grow makes this row span the full card width so the price lands at the card
            edge, matching the failed line item's layout. */}
        <Card borderless asChild className="grow">
          <section>
            <CardContent>
              <LineItem
                name={`${name} ${result.variants_displayable}`}
                quantity={result.show_quantity ? result.quantity : undefined}
                price={result.price}
                card
              />
            </CardContent>
            {result.enabled_integrations.discord ? (
              <CardContent>
                <DiscordButton
                  purchaseId={result.id}
                  connected={false}
                  redirectSettings={{ host: result.domain, protocol: result.protocol }}
                  customState={JSON.stringify({
                    seller_id: result.seller_id,
                    is_custom_domain: !window.location.hostname.endsWith(result.domain.replace("app.", "")),
                  })}
                />
              </CardContent>
            ) : null}
            {result.content_url ? (
              <CardContent>
                <NavigationButton
                  href={result.content_url}
                  color="accent"
                  target="_blank"
                  onClick={trackViewContentClick}
                  className="grow basis-0"
                >
                  {result.view_content_button_text}
                </NavigationButton>
              </CardContent>
            ) : null}
            {result.is_gift_sender_purchase ? (
              <CardContent>
                <div className="grow text-muted">
                  {result.gift_sender_text}{" "}
                  {result.has_files
                    ? "They'll get an email with your note and a download link."
                    : "They'll get an email with your note."}
                </div>
              </CardContent>
            ) : result.extra_purchase_notice ? (
              <CardContent>
                <div className="grow text-muted">{result.extra_purchase_notice}</div>
              </CardContent>
            ) : null}
            {result.is_gift_receiver_purchase ? (
              <CardContent>
                <div className="grow text-muted">{result.gift_receiver_text}</div>
              </CardContent>
            ) : null}
            {result.test_purchase_notice ? (
              <CardContent>
                <div className="grow text-muted">{result.test_purchase_notice}</div>
              </CardContent>
            ) : null}
            <CardContent>
              <div className="generate-invoice grow text-muted">
                Need an invoice for this?{" "}
                <a
                  target="_blank"
                  href={Routes.new_purchase_invoice_path(result.id, { email: result.email })}
                  rel="noreferrer"
                >
                  Generate
                </a>
              </div>
            </CardContent>
          </section>
        </Card>
      </CardContent>

      {result.has_shipping_to_show ? (
        <CardContent>
          <Card borderless asChild className="grow">
            <section>
              <CardContent>
                <LineItem name="Shipping" price={result.shipping_amount} card />
              </CardContent>
            </section>
          </Card>
        </CardContent>
      ) : null}

      {result.has_sales_tax_to_show ? (
        <CardContent>
          <Card borderless asChild className="grow">
            <section>
              <CardContent>
                <LineItem name={result.sales_tax_label ?? ""} price={result.sales_tax_amount} card />
              </CardContent>
            </section>
          </Card>
        </CardContent>
      ) : null}
    </>
  );
};

export const CreateAccountForm = ({
  createAccountData,
  className,
}: {
  createAccountData: Pick<CreateAccountPayload, "email" | "cardParams" | "purchaseId">;
  className?: string | undefined;
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
      className={classNames("flex flex-col gap-4", className)}
    >
      {status === "success" ? (
        <Alert variant="success">Done! Your account has been created. You'll get a confirmation email shortly.</Alert>
      ) : (
        <>
          <div className="space-y-1">
            <h3>Keep everything in one place</h3>
            <p className="text-muted">Create an account to access all of your purchases anytime.</p>
          </div>
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}email`}>Email</Label>
            </FieldsetTitle>
            <Input type="text" readOnly value={createAccountData.email} id={`${uid}email`} />
          </Fieldset>
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}password`}>Password</Label>
            </FieldsetTitle>
            <Input
              type="password"
              placeholder="Enter password"
              value={password}
              onChange={(evt) => setPassword(evt.target.value)}
              id={`${uid}password`}
            />
          </Fieldset>

          <div className="space-y-2">
            <Button type="submit" color="primary" disabled={status === "processing"} className="w-full">
              {status === "processing" ? "Signing up..." : "Sign up"}
            </Button>
            <FieldsetDescription className="text-center">
              By signing up, you agree to our{" "}
              {/* Opens in a new tab: the receipt is in-memory checkout state, so navigating
                  away would destroy it with no way back. */}
              <a href="https://gumroad.com/terms" target="_blank" rel="noreferrer">
                Terms of Use
              </a>
              .
            </FieldsetDescription>
          </div>
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
    <Card className="mx-auto my-8 max-w-2xl">
      <CardContent asChild>
        <header>
          {/* Intentionally not a heading: this is card chrome (a title bar), not document
              structure — keeping it out of the outline avoids an h4 before the h2 below. */}
          <div className="font-bold">Checkout</div>
          <a href={discoverUrl} aria-label="Close" className="text-muted transition-colors hover:text-foreground">
            <XCircle className="size-5" />
          </a>
        </header>
      </CardContent>
      <CardContent asChild details>
        <header className="space-y-1">
          <h2>{results.some(({ result }) => !result.success) ? "Summary" : "Your purchase was successful!"}</h2>

          {results.some(({ result }) => result.success) ? (
            <p className="text-muted">
              {results.some(
                ({ result, item }) =>
                  result.success &&
                  result.non_formatted_price > 0 &&
                  !item.product.is_preorder &&
                  !item.product.free_trial,
              )
                ? `We charged your card and sent a receipt to ${state.email}`
                : `We sent a receipt to ${state.email}`}
            </p>
          ) : null}
        </header>
      </CardContent>
      {results.map(({ result, item }, key) => (
        <LineItemResultEntry key={key} result={result} name={item.product.name} />
      ))}
      {!user && canBuyerSignUp ? (
        <CardContent details>
          <CreateAccountForm
            className="mx-auto w-full max-w-md"
            createAccountData={{
              email: state.email,
              cardParams:
                // Client-confirm methods live in a Stripe ConfirmationToken and carry no
                // cardParamsResult — reading it crashes the whole receipt view (#5784).
                state.status.paymentMethod.type === "not-applicable" ||
                state.status.paymentMethod.type === "saved" ||
                state.status.paymentMethod.type === "payment-element-client-confirm"
                  ? null
                  : state.status.paymentMethod.cardParamsResult.cardParams,
            }}
          />
        </CardContent>
      ) : null}
    </Card>
  );
};
