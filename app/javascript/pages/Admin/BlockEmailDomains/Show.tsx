import React from "react";

import Form from "$app/components/Admin/BlockEmailDomainsForm";

const AdminBlockEmailDomains = () => (
  <Form
    action={Routes.admin_block_email_domains_path()}
    header="To suspend email domains, please enter them separated by comma or newline."
    buttonLabel="Block email domains"
    noticeMessage="Blocking email domains in progress!"
  />
);

export default AdminBlockEmailDomains;
