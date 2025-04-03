import * as React from "react";

import CustomDomain from "$app/components/CustomDomain";

const CustomDomainSection = ({
  verificationStatus,
  customDomain,
  setCustomDomain,
}: {
  verificationStatus: { success: boolean; message: string } | null;
  customDomain: string;
  setCustomDomain: (val: string) => void;
}) => (
  <section>
    <header>
      <h2>Custom domain</h2>
      <a data-helper-prompt="How do I set up a custom domain?">Learn more</a>
    </header>

    <CustomDomain
      verificationStatus={verificationStatus}
      customDomain={customDomain}
      setCustomDomain={setCustomDomain}
      label="Domain"
    />
  </section>
);

export default CustomDomainSection;
