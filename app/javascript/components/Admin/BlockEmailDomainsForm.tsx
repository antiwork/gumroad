import { useForm, usePage } from "@inertiajs/react";
import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

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
      <section>
        <input type="hidden" name="authenticity_token" value={form.data.authenticity_token} />

        <header>{header}</header>

        <p>
          For emails like <code>john@example.com</code>, <code>john@example.net</code>,{" "}
          <code>john@list.example.org</code>, enter what is to the right of the <code>@</code> character.
        </p>

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

        <textarea
          id="identifiers"
          name="email_domains[identifiers]"
          placeholder="Enter email domains here"
          rows={10}
          value={form.data.email_domains.identifiers}
          onChange={setIdentifiers}
          autoComplete="off"
        />

        <button type="submit" className="button primary">
          {buttonLabel}
        </button>
      </section>
    </form>
  );
};

export default Form;
