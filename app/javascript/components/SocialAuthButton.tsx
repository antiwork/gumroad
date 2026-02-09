import { usePage } from "@inertiajs/react";
import * as React from "react";
import * as ReactDOM from "react-dom";

import { BrandName, Button, ButtonProps } from "$app/components/Button";

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
        <span className={`brand-icon brand-icon-${provider}`} />
        {props.children}
      </Button>
    </>
  );
};
