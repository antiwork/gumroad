import { useForm, usePage } from "@inertiajs/react";
import React from "react";

import { Button } from "$app/components/Button";
import CodeSnippet from "$app/components/ui/CodeSnippet";
import { FormSection } from "$app/components/ui/FormSection";
import { Label } from "$app/components/ui/Label";
import { Select } from "$app/components/ui/Select";
import { Textarea } from "$app/components/ui/Textarea";

type PageProps = {
  authenticity_token: string;
  suspend_reasons: string[];
};

const SuspendUsers = () => {
  const { authenticity_token: authenticityToken, suspend_reasons: suspendReasons } = usePage<PageProps>().props;

  const form = useForm({
    authenticity_token: authenticityToken,
    suspend_users: {
      identifiers: "",
      reason: "",
      additional_notes: "",
    },
  });

  const setIdentifiers = (event: React.ChangeEvent<HTMLTextAreaElement>) => {
    form.setData("suspend_users.identifiers", event.target.value);
  };

  const setReason = (event: React.ChangeEvent<HTMLSelectElement>) => {
    form.setData("suspend_users.reason", event.target.value);
  };

  const setAdditionalNotes = (event: React.ChangeEvent<HTMLTextAreaElement>) => {
    form.setData("suspend_users.additional_notes", event.target.value);
  };

  const handleSubmit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();

    form.put(Routes.admin_suspend_users_path(), {
      onSuccess: () => form.reset(),
    });
  };

  return (
    <form onSubmit={handleSubmit}>
      <FormSection
        className="p-4 md:p-8"
        header={
          <>
            To suspend users for terms of service violations, please enter IDs of those users separated by comma or
            newline.
          </>
        }
      >
        <input type="hidden" name="authenticity_token" value={form.data.authenticity_token} />

        <CodeSnippet caption="Example with comma-separated items">3322133, 3738461, 4724778</CodeSnippet>

        <CodeSnippet caption="Example with items separated by newline">
          3322133
          <br />
          3738461
          <br />
          4724778
        </CodeSnippet>

        <Textarea
          id="identifiers"
          name="suspend_users[identifiers]"
          placeholder="Enter user IDs here"
          rows={10}
          value={form.data.suspend_users.identifiers}
          onChange={setIdentifiers}
        />

        <Label htmlFor="reason">Reason</Label>
        <Select
          id="reason"
          name="suspend_users[reason]"
          required
          value={form.data.suspend_users.reason}
          onChange={setReason}
        >
          <option value="">Select a reason</option>
          {suspendReasons.map((reason: string) => (
            <option key={reason} value={reason}>
              {reason}
            </option>
          ))}
        </Select>

        <Label htmlFor="additionalNotes">Notes</Label>
        <Textarea
          id="additionalNotes"
          name="suspend_users[additional_notes]"
          placeholder="Additional info for support team"
          rows={3}
          value={form.data.suspend_users.additional_notes}
          onChange={setAdditionalNotes}
        />

        <Button type="submit" color="primary">
          Suspend users
        </Button>
      </FormSection>
    </form>
  );
};

export default SuspendUsers;
