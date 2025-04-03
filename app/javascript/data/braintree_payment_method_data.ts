import { cast } from "ts-safe-cast";

import { ReusablePayPalBraintreePaymentMethodParams } from "$app/data/payment_method_params";
import { request } from "$app/utils/request";

type BraintreeTransientCustomerToken = { transient_customer_store_key: string | null };

// A nonce can only be tokenized once and will err on subsequent attempts, therefore we will cache the transient token
const cache = new Map<string, BraintreeTransientCustomerToken>();

const tokenizeBraintreeNonce = async (
  braintreeNonce: string,
): Promise<{ type: "done"; token: BraintreeTransientCustomerToken } | { type: "error"; message: string }> => {
  const token = cache.get(braintreeNonce);
  if (token) return { type: "done", token };

  const response = await request({
    method: "POST",
    url: Routes.generate_braintree_transient_customer_token_path(),
    accept: "json",
    data: { braintree_nonce: braintreeNonce },
  });

  if (response.ok) {
    const responseData = cast<{ transient_customer_store_key: string | null } | { error: string }>(
      await response.json(),
    );
    if ("transient_customer_store_key" in responseData) {
      const transientToken = { transient_customer_store_key: responseData.transient_customer_store_key };
      cache.set(braintreeNonce, transientToken);
      return { type: "done", token: transientToken };
    }
    return { type: "error", message: responseData.error };
  }
  return { type: "error", message: "Something went wrong." };
};

export const prepareBraintreePaymentMethodData = async ({
  braintreeNonce,
  deviceData,
}: {
  braintreeNonce: string;
  deviceData: string | null;
}): Promise<ReusablePayPalBraintreePaymentMethodParams> => {
  const tokenResult = await tokenizeBraintreeNonce(braintreeNonce);

  if (tokenResult.type === "error") {
    // TODO: consider an error type for this instead?
    throw new Error(`Could not get reusable PayPal Braintree token: ${tokenResult.message}`);
  }

  return {
    status: "success",
    type: "paypal-braintree",
    reusable: true,
    braintree_transient_customer_store_key: tokenResult.token.transient_customer_store_key,
    braintree_device_data: deviceData,
  };
};
