import { usePage, Head } from "@inertiajs/react";
import React from "react";

import Form from "./Form";

type Props = {
  suspend_reasons: string[];
  authenticity_token: string;
  title: string;
};

const AdminSuspendUsers = () => {
  const { suspend_reasons, authenticity_token, title } = usePage<Props>().props;

  return (
    <>
      <Head title={title} />
      <Form authenticity_token={authenticity_token} suspend_reasons={suspend_reasons} />
    </>
  );
};

export default AdminSuspendUsers;
