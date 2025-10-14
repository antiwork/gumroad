import React from "react";

import Form from "$app/components/Admin/BlockEmailDomainsForm";

const AdminUnblockEmailDomains = () => (
  <Form
    action={Routes.admin_unblock_email_domains_path()}
    header="To suspend email domains, please enter them separated by comma or newline."
    button_label="Unblock email domains"
    notice_message="Unblocking email domains in progress!"
  />
);

export default AdminUnblockEmailDomains;
