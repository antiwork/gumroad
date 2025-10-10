import { usePage } from "@inertiajs/react";
import React from "react";

import Form from "./Form";

type Props = {
  suspend_reasons: string[];
  authenticity_token: string;
};

const AdminSuspendUsers = () => {
  const { suspend_reasons, authenticity_token } = usePage<Props>().props;

  return <Form authenticity_token={authenticity_token} suspend_reasons={suspend_reasons} />;
};

export default AdminSuspendUsers;
