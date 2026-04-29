import { useForm, usePage } from "@inertiajs/react";
import React from "react";

import { Button } from "$app/components/Button";
import CodeSnippet from "$app/components/ui/CodeSnippet";
import { FormSection } from "$app/components/ui/FormSection";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { Select } from "$app/components/ui/Select";
import { Textarea } from "$app/components/ui/Textarea";

type PageProps = {
  authenticity_token: string;
  suspend_reasons: string[];
};

const DEFAULT_SCHEDULED_PAYOUT_DELAY_DAYS = "21";

const NOTES_SUGGESTIONS = [
  "Adult (18+) content",
  "Stripe reported high risk",
  "Intellectual property infringement",
  "General non-compliance",
  "Credit repair services",
  "Pirated/unauthorized software or content",
  "Counterfeit or copied products from another creator",
  "DMCA/copyright infringement",
  "Card testing or fraudulent transactions",
  "High chargeback rate",
  "Shared bank account with previously suspended user",
  "Unauthorized resale of third-party products",
  "Spam or SEO manipulation",
  "Phishing or scam products",
  "Physical goods only (not permitted)",
  "Negative balance over 3 months",
  "No products / empty storefront with balance",
];

const SuspendUsers = () => {
  const { authenticity_token: authenticityToken, suspend_reasons: suspendReasons } = usePage<PageProps>().props;

  const form = useForm({
    authenticity_token: authenticityToken,
    suspend_users: {
      identifiers: "",
      reason: "",
      additional_notes: "",
    },
    scheduled_payout: {
      action: "payout",
      delay_days: DEFAULT_SCHEDULED_PAYOUT_DELAY_DAYS,
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

  const setPayoutAction = (event: React.ChangeEvent<HTMLSelectElement>) => {
    form.setData("scheduled_payout.action", event.target.value);
  };

  const setPayoutDelayDays = (event: React.ChangeEvent<HTMLInputElement>) => {
    form.setData("scheduled_payout.delay_days", event.target.value);
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
        <div className="flex flex-wrap gap-1 mb-2">
          {NOTES_SUGGESTIONS.map((suggestion) => (
            <button
              key={suggestion}
              type="button"
              className="rounded-full border px-2.5 py-0.5 text-xs hover:bg-black hover:text-white transition-colors"
              onClick={() => {
                const current = form.data.suspend_users.additional_notes;
                const sep = current && !current.endsWith("\n") ? "\n" : "";
                form.setData("suspend_users.additional_notes", current + sep + suggestion);
              }}
            >
              {suggestion}
            </button>
          ))}
        </div>
        <Textarea
          id="additionalNotes"
          name="suspend_users[additional_notes]"
          placeholder="Additional info for support team"
          rows={3}
          value={form.data.suspend_users.additional_notes}
          onChange={setAdditionalNotes}
        />

        <div className="flex flex-col gap-2">
          <div className="flex items-end gap-2">
            <div className="flex flex-1 flex-col gap-2">
              <Label htmlFor="scheduled_payout_action">Balance action</Label>
              <Select
                id="scheduled_payout_action"
                name="scheduled_payout[action]"
                value={form.data.scheduled_payout.action}
                onChange={setPayoutAction}
              >
                <option value="payout">Payout after delay</option>
                <option value="refund">Refund purchases</option>
                <option value="hold">Hold (manual release)</option>
              </Select>
            </div>
            {form.data.scheduled_payout.action !== "hold" ? (
              <div className="flex w-24 flex-col gap-2">
                <Label htmlFor="scheduled_payout_delay">Delay (days)</Label>
                <Input
                  id="scheduled_payout_delay"
                  type="number"
                  name="scheduled_payout[delay_days]"
                  min={0}
                  value={form.data.scheduled_payout.delay_days}
                  onChange={setPayoutDelayDays}
                />
              </div>
            ) : null}
          </div>
          <small>
            Only applied to users with an unpaid balance. Users with a zero balance are suspended but no scheduled
            payout is created.
          </small>
        </div>

        <Button type="submit" color="primary">
          Suspend users
        </Button>
      </FormSection>
    </form>
  );
};

export default SuspendUsers;
