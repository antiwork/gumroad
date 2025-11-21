import * as React from "react";
import * as ReactDOM from "react-dom";
import { cast } from "ts-safe-cast";

import { BrandName, Button, ButtonProps } from "$app/components/Button";
import { useRunOnce } from "$app/components/useRunOnce";

export const SocialAuthButton = ({
  href,
  provider,
  ...props
}: {
  href: string;
  provider: BrandName;
} & ButtonProps) => {
  const formRef = React.useRef<HTMLFormElement>(null);
  const [csrfToken, setCsrfToken] = React.useState("");
  useRunOnce(() => setCsrfToken(cast(document.querySelector("meta[name=csrf-token]")?.getAttribute("content"))));

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
      <Button
        {...props}
        brand={provider}
        onClick={() => formRef.current?.submit()}
      />
    </>
  );
};
