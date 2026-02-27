import {
  Amazon,
  Android,
  Apple,
  Discord,
  Facebook,
  Google,
  Paypal,
  Stripe,
  Twitter,
  ZoomWorkplace,
} from "@boxicons/react";
import { usePage } from "@inertiajs/react";
import * as React from "react";
import * as ReactDOM from "react-dom";

import { BrandName, Button, ButtonProps } from "$app/components/Button";

const brandIcons: Record<BrandName, typeof Paypal> = {
  paypal: Paypal,
  discord: Discord,
  stripe: Stripe,
  facebook: Facebook,
  twitter: Twitter,
  apple: Apple,
  android: Android,
  kindle: Amazon,
  zoom: ZoomWorkplace,
  google: Google,
};

export const SocialAuthButton = ({
  href,
  provider,
  ...props
}: {
  href: string;
  provider: BrandName;
} & ButtonProps) => {
  const formRef = React.useRef<HTMLFormElement>(null);
  const { authenticity_token: csrfToken } = usePage<{ authenticity_token: string }>().props;
  const BrandIcon = brandIcons[provider];

  return (
    // Omniauth requires a non-AJAX POST request to redirect to the provider, so we need to submit a form.
    // Having it in a portal makes styling simpler and avoids invalid nesting (e.g. form in form).
    <>
      {csrfToken
        ? ReactDOM.createPortal(
            <form method="post" action={href} ref={formRef}>
              <input type="hidden" name="authenticity_token" value={csrfToken} />
            </form>,
            document.body,
          )
        : null}
      <Button {...props} color={provider} onClick={() => formRef.current?.submit()}>
        <BrandIcon pack="brands" className="size-5" />
        {props.children}
      </Button>
    </>
  );
};
