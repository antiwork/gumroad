import { useForm, usePage } from "@inertiajs/react";
import React from "react";

import { Button } from "$app/components/Button";
import CodeSnippet from "$app/components/ui/CodeSnippet";
import { FormSection } from "$app/components/ui/FormSection";
import { Textarea } from "$app/components/ui/Textarea";

export type Props = {
  action: string;
  header: string;
  buttonLabel: string;
};

const Form = ({ action, header, buttonLabel }: Props) => {
  const { authenticity_token } = usePage<{ authenticity_token: string }>().props;

  const form = useForm({
    authenticity_token,
    email_domains: {
      identifiers: "",
    },
  });

  const handleSubmit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();

    form.put(action, { only: ["flash"], onSuccess: () => form.reset() });
  };

  const setIdentifiers = (event: React.ChangeEvent<HTMLTextAreaElement>) => {
    form.setData("email_domains.identifiers", event.target.value);
  };

  return (
    <form onSubmit={handleSubmit}>
      <FormSection
        className="p-4 md:p-8"
        header={
          <>
            <p>{header}</p>
            <p>
              For emails like <code>john@example.com</code>, <code>john@example.net</code>,{" "}
              <code>john@list.example.org</code>, enter what is to the right of the <code>@</code> character.
            </p>
          </>
        }
      >
        <input type="hidden" name="authenticity_token" value={form.data.authenticity_token} />

        <CodeSnippet caption="Example with comma-separated items">
          example.com, example.net, list.example.org
        </CodeSnippet>

        <CodeSnippet caption="Example with items separated by newline">
          example.com
          <br />
          example.net
          <br />
          list.example.org
        </CodeSnippet>

        <Textarea
          id="identifiers"
          name="email_domains[identifiers]"
          placeholder="Enter email domains here"
          rows={10}
          value={form.data.email_domains.identifiers}
          onChange={setIdentifiers}
          autoComplete="off"
        />

        <Button type="submit" color="primary">
          {buttonLabel}
        </Button>
      </FormSection>
    </form>
  );
};

export default Form;
