import React from "react";

import DateTimeWithRelativeTooltip from "$app/components/Admin/DateTimeWithRelativeTooltip";
import Loading from "$app/components/Admin/Loading";

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

export default EmailChanges;
