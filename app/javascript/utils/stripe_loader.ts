import { loadStripe, Stripe, StripeConstructorOptions } from "@stripe/stripe-js";
import { cast } from "ts-safe-cast";

let stripeInstance: Promise<Stripe> | undefined;

export const getStripeInstance = async () => {
  if (stripeInstance) return stripeInstance;
  stripeInstance = loadStripeInstance();
  return stripeInstance;
};

export const getConnectedAccountStripeInstance = async (stripeAccount: string) => loadStripeInstance(stripeAccount);

const loadStripeInstance = async (stripeAccount?: string) => {
  const publicKeyTag = document.querySelector<HTMLElement>("meta[property='stripe:pk']");
  const apiVersionTag = document.querySelector<HTMLElement>("meta[property='stripe:api_version']");
  const publicKey = cast<string>(publicKeyTag?.getAttribute("value"));
  const apiVersion = apiVersionTag?.getAttribute("value");

  const options: StripeConstructorOptions = {};
  if (apiVersion) options.apiVersion = apiVersion;
  if (stripeAccount) options.stripeAccount = stripeAccount;

  const instance = await loadStripe(publicKey, options);
  if (!instance) throw new Error("Failed to load Stripe.");
  return instance;
};
