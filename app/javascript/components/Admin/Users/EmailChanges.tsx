import React from "react";
import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

import DateTimeWithRelativeTooltip from "$app/components/Admin/DateTimeWithRelativeTooltip";
import Loading from "$app/components/Admin/Loading";
import type { User } from "$app/components/Admin/Users/User";

type AdminUserEmailChangesProps = {
  user: User;
};

export type EmailChangesProps = {
  created_at: string;
  changes: {
    email?: (string | null)[];
    payment_address?: (string | null)[];
  };
}[];

export type FieldsProps = ["email", "payment_address"];

type EmailChangesComponentProps = {
  fields: FieldsProps;
  emailChanges: EmailChangesProps;
  isLoading: boolean;
};

const EmailChanges = ({ fields, emailChanges, isLoading }: EmailChangesComponentProps) => {
  if (isLoading) return <Loading />;

  if (emailChanges.length === 0) return <div>No email changes found.</div>;

  return (
    <table>
      <thead>
        <tr>
          <th>Field</th>
          <th>Old</th>
          <th>New</th>
          <th>Changed</th>
        </tr>
      </thead>
      <tbody>
        {fields.map((field) => (
          <React.Fragment key={field}>
            {Object.values(emailChanges).map(({ created_at, changes }) => {
              const fieldChanges = changes[field];
              if (!fieldChanges) return null;

              const [oldValue, newValue] = fieldChanges;

              return (
                <tr key={created_at}>
                  <td data-label="Field">{field}</td>
                  <td data-label="Old">{oldValue || "(Not set)"}</td>
                  <td data-label="New">{newValue || "(Not set)"}</td>
                  <td data-label="Changed">
                    <DateTimeWithRelativeTooltip date={created_at} />
                  </td>
                </tr>
              );
            })}
          </React.Fragment>
        ))}
      </tbody>
    </table>
  );
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
