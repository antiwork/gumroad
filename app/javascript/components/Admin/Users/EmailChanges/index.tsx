import React from "react";
import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

import EmailChanges, {
  type EmailChangesProps,
  type FieldsProps,
} from "$app/components/Admin/Users/EmailChanges/EmailChanges";
import type { User } from "$app/components/Admin/Users/User";

type AdminUserEmailChangesProps = {
  user: User;
};

const AdminUserEmailChanges = ({ user }: AdminUserEmailChangesProps) => {
  const [open, setOpen] = React.useState(false);
  const [isLoading, setIsLoading] = React.useState(false);
  const [data, setData] = React.useState<{ email_changes: EmailChangesProps; fields: FieldsProps }>({
    email_changes: [],
    fields: ["email", "payment_address"],
  });

  const fetchEmailChanges = async () => {
    setIsLoading(true);
    const response = await request({
      method: "GET",
      url: Routes.admin_user_email_changes_path(user.id),
      accept: "json",
    });
    const data = cast<{ email_changes: EmailChangesProps; fields: FieldsProps }>(await response.json());
    setData(data);
    setIsLoading(false);
  };

  const onToggle = (e: React.MouseEvent<HTMLDetailsElement>) => {
    setOpen(e.currentTarget.open);
    if (e.currentTarget.open) {
      void fetchEmailChanges();
    }
  };

  return (
    <>
      <hr />
      <details open={open} onToggle={onToggle}>
        <summary>
          <h3>Email changes</h3>
        </summary>
        <EmailChanges fields={data.fields} emailChanges={data.email_changes} isLoading={isLoading} />
      </details>
    </>
  );
};

export default AdminUserEmailChanges;
