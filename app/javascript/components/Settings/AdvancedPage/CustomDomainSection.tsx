import * as React from "react";

import CustomDomain from "$app/components/CustomDomain";
import { FormSection } from "$app/components/ui/FormSection";

const CustomDomainSection = ({
  verificationStatus,
  customDomain,
  setCustomDomain,
}: {
  verificationStatus: { success: boolean; message: string } | null;
  customDomain: string;
  setCustomDomain: (val: string) => void;
}) => (
  <FormSection
    header={
      <>
        <h2>Custom domain</h2>
        <a href="/help/article/153-setting-up-a-custom-domain" target="_blank" rel="noreferrer">
          Learn more
        </a>
      </>
    }
  >
    <CustomDomain
      verificationStatus={verificationStatus}
      customDomain={customDomain}
      setCustomDomain={setCustomDomain}
      label="Domain"
    />
  </FormSection>
);

export default CustomDomainSection;
