import { loadConnectAndInitialize, StripeConnectInstance } from "@stripe/connect-js";
import { loadStripe, Stripe, StripeConstructorOptions } from "@stripe/stripe-js";
import { cast } from "ts-safe-cast";

import { createAccountSession } from "$app/data/stripe_connect";
import { getCssVariable } from "$app/utils/styles";

import { readDesignSettings } from "$app/components/DesignSettings";

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

let stripeConnectInstance: StripeConnectInstance | undefined;

export const getStripeConnectInstance = () => {
  if (stripeConnectInstance) return stripeConnectInstance;
  stripeConnectInstance = loadStripeConnectInstance();
  return stripeConnectInstance;
};

const loadStripeConnectInstance = () => {
  const publicKeyTag = document.querySelector<HTMLElement>("meta[property='stripe:pk']");
  const publicKey = cast<string>(publicKeyTag?.getAttribute("value"));

  const designSettings = readDesignSettings();

  const instance = loadConnectAndInitialize({
    publishableKey: publicKey,
    fetchClientSecret: createAccountSession,
    fonts: [
      {
        family: designSettings.font.name,
        src: `url(${designSettings.font.url})`,
      },
    ],
    appearance: {
      overlays: "dialog",
      variables: {
        actionPrimaryColorText: getRgbCssVariable("color"),
        colorText: getRgbCssVariable("color"),
        colorSecondaryText: appendAlpha(extractRgbValues("color"), "0.5"),
        colorBackground: getCssVariable("body-bg"),
        colorPrimary: getRgbCssVariable("accent"),
        colorDanger: getRgbCssVariable("danger"),
        colorBorder: getBorder(),
        buttonPrimaryColorBorder: getBorder(),
        buttonPrimaryColorText: getRgbCssVariable("contrast-accent"),
        bodyMdFontWeight: "400",
        bodySmFontWeight: "400",
        headingXlFontWeight: "400",
        headingLgFontWeight: "400",
        headingMdFontWeight: "400",
        headingSmFontWeight: "400",
        headingXsFontWeight: "400",
        labelMdFontWeight: "400",
        labelSmFontWeight: "400",
        formAccentColor: getRgbCssVariable("accent"),
      },
    },
  });

  return instance;
};

const extractRgbValues = (name: string) => getCssVariable(name).trim().split(" ").join(", ");

const getRgbCssVariable = (name: string) => `rgb(${extractRgbValues(name)})`;

const appendAlpha = (color: string, alpha: string) => `rgba(${color}, ${alpha})`;

const getBorder = () => {
  const color = extractRgbValues("color");
  const alpha = getCssVariable("border-alpha");
  return appendAlpha(color, alpha);
};
