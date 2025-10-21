import React from "react";

import Form from "$app/components/Admin/BlockEmailDomainsForm";

const AdminUnblockEmailDomains = () => (
  <Form
    action={Routes.admin_unblock_email_domains_path()}
    header="To suspend email domains, please enter them separated by comma or newline."
    buttonLabel="Unblock email domains"
  />
);

export default AdminUnblockEmailDomains;
