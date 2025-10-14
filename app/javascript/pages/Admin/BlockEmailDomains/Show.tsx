import { usePage } from "@inertiajs/react";
import React from "react";

import Form from "./Form";

type Props = {
  authenticity_token: string;
};

const AdminBlockEmailDomains = () => {
  const { authenticity_token } = usePage<Props>().props;

  return (
    <Form
      action={Routes.admin_block_email_domains_path()}
      authenticity_token={authenticity_token}
      header="To suspend email domains, please enter them separated by comma or newline."
      button_label="Block email domains"
      notice_message="Blocking email domains in progress!"
    />
  );
};

export default AdminBlockEmailDomains;
