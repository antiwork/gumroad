import cx from "classnames";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Pill } from "$app/components/ui/Pill";

type VerificationState = "initial" | "verifying" | "success" | "failure";

const CustomDomain = ({
  verificationStatus,
  customDomain,
  setCustomDomain,
  label,
  includeLearnMoreLink = false,
  productId = null,
}: {
  verificationStatus: { success: boolean; message: string } | null;
  customDomain: string;
  setCustomDomain: (val: string) => void;
  label: string;
  includeLearnMoreLink?: boolean;
  productId?: string | null;
}) => {
  const [verificationInfo, setVerificationInfo] = React.useState<{
    buttonState: VerificationState;
    state: VerificationState;
    message: string;
  }>({
    buttonState: "initial",
    state: verificationStatus ? (verificationStatus.success ? "success" : "failure") : "initial",
    message: verificationStatus?.message || "",
  });
  const uid = React.useId();

  React.useEffect(() => {
    let timeout: ReturnType<typeof setTimeout> | undefined;
    if (["success", "failure"].includes(verificationInfo.state)) {
      clearTimeout(timeout);
      timeout = setTimeout(() => {
        setVerificationInfo((prevState) => ({ ...prevState, buttonState: "initial" }));
      }, 2000);
    }
    return () => clearTimeout(timeout);
  }, [verificationInfo.buttonState]);

  const verifyCustomDomain = asyncVoid(async () => {
    setVerificationInfo({ buttonState: "verifying", state: "verifying", message: "" });

    try {
      const response = await request({
        method: "POST",
        accept: "json",
        url: Routes.custom_domain_verifications_path(),
        data: { domain: customDomain, product_id: productId },
      });
      const responseData = cast<{ success: boolean; message: string }>(await response.json());
      if (!responseData.success) throw new ResponseError(responseData.message);
      setVerificationInfo({ buttonState: "success", state: "success", message: responseData.message });
    } catch (e) {
      assertResponseError(e);
      setVerificationInfo({ buttonState: "failure", state: "failure", message: e.message });
    }
  });

  return (
    <fieldset
      className={cx({
        success: verificationInfo.state === "success",
        danger: verificationInfo.state === "failure",
      })}
    >
      <legend>
        <label htmlFor={uid}>{label}</label>
        {includeLearnMoreLink ? (
          <a href="/help/article/153-setting-up-a-custom-domain" target="_blank" rel="noreferrer">
            Learn more
          </a>
        ) : null}
      </legend>
      <div className="input input-wrapper">
        <input
          id={uid}
          placeholder="yourdomain.com"
          type="text"
          value={customDomain}
          onChange={(e) => {
            setCustomDomain(e.target.value);
            setVerificationInfo({ buttonState: "initial", state: "initial", message: "" });
          }}
        />
        {customDomain.trim() !== "" ? (
          <Pill asChild>
            <Button
              className="rounded-full! px-3! py-2!"
              onClick={verifyCustomDomain}
              disabled={verificationInfo.buttonState === "verifying"}
            >
              <div>
                {
                  {
                    initial: "Verify",
                    verifying: "Verifying...",
                    success: "Verified!",
                    failure: "Verify",
                  }[verificationInfo.buttonState]
                }
              </div>
            </Button>
          </Pill>
        ) : null}
      </div>
      <small>{verificationInfo.message}</small>
    </fieldset>
  );
};

export default CustomDomain;
