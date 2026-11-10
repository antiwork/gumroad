import * as React from "react";

import { Alert } from "$app/components/ui/Alert";
import { LinkButton } from "$app/components/ui/LinkButton";
import { useRunOnce } from "$app/components/useRunOnce";

import hands from "$assets/images/illustrations/hands.png";

// The advice only applies to a published product, so closing it on a draft must not use up the dismissal.
export const DiscoverEligibilityPromo = ({ rememberDismissal }: { rememberDismissal: boolean }) => {
  const [show, setShow] = React.useState(false);

  useRunOnce(() => {
    if (localStorage.getItem("showDiscoverEligibilityPromo") !== "false") setShow(true);
  });

  if (!show) return null;

  return (
    <Alert role="status">
      <div className="flex items-center gap-2">
        <img src={hands} alt="" className="size-12" />
        <div className="flex flex-1 flex-col gap-2">
          <div>
            To appear on Gumroad Discover, make sure to meet all the{" "}
            <a href="/help/article/79-gumroad-discover" target="_blank" rel="noreferrer">
              eligibility criteria
            </a>
            , which includes making at least one successful sale and completing the Risk Review process explained in
            detail{" "}
            <a href="/help/article/13-getting-paid" target="_blank" rel="noreferrer">
              here
            </a>
            .
          </div>
          <LinkButton
            className="w-max"
            onClick={() => {
              if (rememberDismissal) localStorage.setItem("showDiscoverEligibilityPromo", "false");
              setShow(false);
            }}
          >
            Close
          </LinkButton>
        </div>
      </div>
    </Alert>
  );
};
