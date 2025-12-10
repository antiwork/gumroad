import React from "react";
import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

import DateTimeWithRelativeTooltip from "$app/components/Admin/DateTimeWithRelativeTooltip";
import type { User } from "$app/components/Admin/Users/User";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";

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
  if (isLoading) return <LoadingSpinner />;

  if (emailChanges.length === 0) return <div>No email changes found.</div>;

  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Field</TableHead>
          <TableHead>Old</TableHead>
          <TableHead>New</TableHead>
          <TableHead>Changed</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {fields.map((field) => (
          <React.Fragment key={field}>
            {Object.values(emailChanges).map(({ created_at, changes }) => {
              const fieldChanges = changes[field];
              if (!fieldChanges) return null;

              const [oldValue, newValue] = fieldChanges;

              return (
                <TableRow key={created_at}>
                  <TableCell>{field}</TableCell>
                  <TableCell>{oldValue || "(Not set)"}</TableCell>
                  <TableCell>{newValue || "(Not set)"}</TableCell>
                  <TableCell>
                    <DateTimeWithRelativeTooltip date={created_at} />
                  </TableCell>
                </TableRow>
              );
            })}
          </React.Fragment>
        ))}
      </TableBody>
    </Table>
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
      url: Routes.admin_user_email_changes_path(user.external_id),
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
