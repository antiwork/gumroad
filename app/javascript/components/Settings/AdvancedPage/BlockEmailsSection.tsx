import * as React from "react";

import { isValidEmail } from "$app/utils/email";

type Props = {
  blockedEmails: string;
  setBlockedEmails: (emails: string) => void;
};
const BlockEmailsSection = ({ blockedEmails, setBlockedEmails }: Props) => {
  const uid = React.useId();
  const sanitizeBlockedEmails = () => {
    if (blockedEmails.length === 0) {
      return;
    }

    setBlockedEmails(
      [
        ...new Set( // remove duplicate emails
          blockedEmails
            .toLowerCase()
            .replace(/[\r\n]+/gu, ",") // replace newlines with commas
            .replace(/\s/gu, "") // remove all whitespaces
            .split(/[,]+/gu) // split by commas
            .map((email) => {
              if (!isValidEmail(email)) return email;

              const [localPart, domain] = email.split("@");
              return [
                // Normalize local-part (https://en.wikipedia.org/wiki/Email_address#Common_local-part_semantics)
                localPart
                  .replace(/\+.*/u, "") // normalize plus sub-addressing
                  .replace(/\./gu, ""), // normalize dots
                domain,
              ].join("@");
            }),
        ),
      ].join("\n"),
    );
  };

  return (
    <section className="p-4! md:p-8!">
      <header>
        <h2>Mass-block emails</h2>
        <a href="/help/article/329-customer-moderation" target="_blank" rel="noreferrer">
          Learn more
        </a>
      </header>
      <fieldset>
        <legend>
          <label htmlFor={uid}>Block emails from purchasing</label>
        </legend>
        <div className="input input-wrapper">
          <textarea
            id={uid}
            placeholder={["name@example.com", "name@example.net", "name@example.org"].join("\n")}
            rows={4}
            value={blockedEmails}
            onChange={(e) => setBlockedEmails(e.target.value)}
            onBlur={sanitizeBlockedEmails}
          />
        </div>
        <small>Please enter each email address on a new line.</small>
      </fieldset>
    </section>
  );
};

export default BlockEmailsSection;
