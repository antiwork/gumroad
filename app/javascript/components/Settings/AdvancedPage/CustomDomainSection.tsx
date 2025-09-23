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
  <section className="!p-4 md:!p-8">
    <header>
      <h2>Custom domain</h2>
      <a href="/help/article/153-setting-up-a-custom-domain" target="_blank" rel="noreferrer">
        Learn more
      </a>
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
