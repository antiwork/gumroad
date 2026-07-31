import * as React from "react";
import typia from "typia";

import { request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Checkbox } from "$app/components/ui/Checkbox";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { Select } from "$app/components/ui/Select";

export type Guardian = {
  id: string;
  first_name: string | null;
  last_name: string | null;
  email: string | null;
  phone: string | null;
  date_of_birth: string | null;
  street_address: string | null;
  city: string | null;
  state: string | null;
  zip_code: string | null;
  country: string | null;
  nationality: string | null;
  has_individual_tax_id: boolean;
  accepted_terms: boolean;
  has_completed_info: boolean;
};

export type LegalGuardianProps = {
  required: boolean;
  unsupported: boolean;
  blocking_payouts: boolean;
  guardian: Guardian | null;
};

type FormState = {
  first_name: string;
  last_name: string;
  email: string;
  phone: string;
  date_of_birth: string;
  street_address: string;
  city: string;
  state: string;
  zip_code: string;
  individual_tax_id: string;
  accept_terms: boolean;
};

const blankFormState = (): FormState => ({
  first_name: "",
  last_name: "",
  email: "",
  phone: "",
  date_of_birth: "",
  street_address: "",
  city: "",
  state: "",
  zip_code: "",
  individual_tax_id: "",
  accept_terms: false,
});

const guardianToFormState = (guardian: Guardian): FormState => ({
  first_name: guardian.first_name ?? "",
  last_name: guardian.last_name ?? "",
  email: guardian.email ?? "",
  phone: guardian.phone ?? "",
  date_of_birth: guardian.date_of_birth ?? "",
  street_address: guardian.street_address ?? "",
  city: guardian.city ?? "",
  state: guardian.state ?? "",
  zip_code: guardian.zip_code ?? "",
  // Never prefilled. The stored identifier is encrypted with a key the server cannot read back, so
  // the field starts empty and an empty field on save means "keep what is on file".
  individual_tax_id: "",
  accept_terms: guardian.accepted_terms,
});

// The guardian's own country is the seller's: our payment partner adds them as a second person on
// the seller's account, and a person on that account has to be in the account's country. So there is
// no country picker here, and the state list is the one the seller's country uses.
const LegalGuardianSection = ({
  legalGuardian,
  sellerCountry,
  states,
  isFormDisabled,
  onSaved,
}: {
  legalGuardian: LegalGuardianProps;
  sellerCountry: string | null;
  states: { code: string; name: string }[];
  isFormDisabled: boolean;
  onSaved: () => void;
}) => {
  const uid = React.useId();
  const existing = legalGuardian.guardian;
  const [formState, setFormState] = React.useState<FormState>(() =>
    existing ? guardianToFormState(existing) : blankFormState(),
  );
  const [isSaving, setIsSaving] = React.useState(false);
  const [formError, setFormError] = React.useState<string | null>(null);

  const updateForm = (patch: Partial<FormState>) => setFormState((previous) => ({ ...previous, ...patch }));

  // A seller our payment partner offers no guardian path for gets told so and nothing else. Showing
  // them the form would collect an adult's identity details for a verification that cannot succeed.
  if (legalGuardian.unsupported) {
    return (
      <section className="grid gap-4">
        <header className="grid gap-2">
          <h3 className="text-lg font-bold">Age requirement</h3>
        </header>
        <Alert variant="warning">
          Our payment partner cannot verify a seller under 18 in your country, even with a legal guardian on the
          account. You can keep selling, and your balance is safe — payouts will start once you turn 18.
        </Alert>
      </section>
    );
  }

  if (!legalGuardian.required) return null;

  // Required fields are checked here rather than by the browser: this section cannot be a <form> (see
  // the render below), so `required` on the inputs is inert. Mirrors Guardian#has_completed_info? —
  // without this the endpoint saves a partial guardian and reports success, leaving payouts blocked
  // with nothing telling the seller which field is missing.
  const missingRequiredField = () => {
    if (formState.first_name.trim() === "") return "your guardian's first name";
    if (formState.last_name.trim() === "") return "your guardian's last name";
    if (formState.email.trim() === "") return "your guardian's email";
    if (formState.date_of_birth === "") return "your guardian's date of birth";
    if (formState.street_address.trim() === "") return "your guardian's address";
    if (formState.city.trim() === "") return "your guardian's city";
    if (states.length > 0 && formState.state === "") return "your guardian's state";
    if (formState.zip_code.trim() === "") return "your guardian's ZIP code";
    if (!existing?.has_individual_tax_id && formState.individual_tax_id.trim() === "") {
      return sellerCountry === "US" ? "your guardian's Social Security number" : "your guardian's personal ID number";
    }
    return null;
  };

  const handleSubmit = async () => {
    if (isSaving) return;

    const missing = missingRequiredField();
    if (missing !== null) {
      const message = `Please enter ${missing}.`;
      setFormError(message);
      showAlert(message, "error");
      return;
    }

    setIsSaving(true);
    setFormError(null);

    const payload: Record<string, unknown> = {
      first_name: formState.first_name,
      last_name: formState.last_name,
      email: formState.email,
      phone: formState.phone,
      date_of_birth: formState.date_of_birth,
      street_address: formState.street_address,
      city: formState.city,
      state: formState.state,
      zip_code: formState.zip_code,
      accept_terms: formState.accept_terms,
    };
    // Only sent when the seller typed one. Sending the empty string would overwrite the identifier on
    // file with nothing and quietly make a complete guardian incomplete again.
    if (formState.individual_tax_id.trim() !== "") payload.individual_tax_id = formState.individual_tax_id.trim();

    try {
      const response = await request({
        method: existing ? "PUT" : "POST",
        accept: "json",
        url: existing ? Routes.settings_guardian_path(existing.id) : Routes.settings_guardians_path(),
        data: { guardian: payload },
      });
      if (!response.ok) {
        const body = typia.assert<{ error?: string }>(await response.json().catch(() => ({})));
        throw new ResponseError(body.error ?? "Something went wrong.");
      }
      // typia rather than a cast, so a response shape that drifts from this contract fails loudly
      // here instead of writing undefined into the form and reporting success.
      const { guardian } = typia.assert<{ guardian: Guardian }>(await response.json());

      setFormState(guardianToFormState(guardian));
      showAlert(
        guardian.has_completed_info
          ? "Your legal guardian's details are saved. Payouts will resume on your next payout date."
          : "Your legal guardian's details are saved.",
        "success",
      );
      // Last, and after the local form state is already correct: this refetches the page's own
      // guardian props, which is what moves the payout-hold notice. Doing it before the setState
      // above would let the reload's re-render race the form's own update.
      onSaved();
    } catch (error) {
      const message = error instanceof ResponseError ? error.message : "Something went wrong.";
      setFormError(message);
      showAlert(message, "error");
    } finally {
      setIsSaving(false);
    }
  };

  return (
    <section className="grid gap-4">
      <header className="grid gap-2">
        <h3 className="text-lg font-bold">Legal guardian</h3>
        <p className="text-muted">
          Because you are under 18, our payment partner needs an adult to take legal responsibility for your payout
          account before it can verify you. You stay the owner of this account and of everything you sell — your
          guardian is added only so the account can be verified.
        </p>
      </header>

      {legalGuardian.blocking_payouts ? (
        <Alert variant="warning">
          Your payouts are on hold until your guardian's details are complete. Your balance is safe in the meantime, and
          payouts start automatically once this is done.
        </Alert>
      ) : (
        <Alert variant="success">Your guardian's details are complete and your payouts are running normally.</Alert>
      )}

      {/* A div, not a form, and the button below is type="button" with an onClick. The payout-settings
          page wraps this whole section in its own <form>, and a nested form is invalid HTML — the
          browser discards the inner one, so a submit button here would silently submit the PAGE's form
          and the guardian would never be saved. */}
      <div className="grid gap-4">
        <div>{formError ? <Alert variant="danger">{formError}</Alert> : null}</div>

        <div className="grid gap-5 md:auto-cols-fr md:grid-flow-col">
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-first-name`}>Guardian's first name</Label>
            </FieldsetTitle>
            <Input
              id={`${uid}-first-name`}
              type="text"
              disabled={isFormDisabled}
              value={formState.first_name}
              onChange={(event) => updateForm({ first_name: event.target.value })}
            />
          </Fieldset>
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-last-name`}>Guardian's last name</Label>
            </FieldsetTitle>
            <Input
              id={`${uid}-last-name`}
              type="text"
              disabled={isFormDisabled}
              value={formState.last_name}
              onChange={(event) => updateForm({ last_name: event.target.value })}
            />
          </Fieldset>
        </div>

        <div className="grid gap-5 md:auto-cols-fr md:grid-flow-col">
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-email`}>Guardian's email</Label>
            </FieldsetTitle>
            <Input
              id={`${uid}-email`}
              type="email"
              disabled={isFormDisabled}
              value={formState.email}
              onChange={(event) => updateForm({ email: event.target.value })}
            />
          </Fieldset>
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-phone`}>Guardian's phone number</Label>
            </FieldsetTitle>
            <Input
              id={`${uid}-phone`}
              type="tel"
              disabled={isFormDisabled}
              value={formState.phone}
              onChange={(event) => updateForm({ phone: event.target.value })}
            />
          </Fieldset>
        </div>

        <Fieldset>
          <FieldsetTitle>
            <Label htmlFor={`${uid}-date-of-birth`}>Guardian's date of birth</Label>
          </FieldsetTitle>
          <Input
            id={`${uid}-date-of-birth`}
            type="date"
            disabled={isFormDisabled}
            value={formState.date_of_birth}
            onChange={(event) => updateForm({ date_of_birth: event.target.value })}
          />
          <FieldsetDescription>Your guardian must be 18 or older.</FieldsetDescription>
        </Fieldset>

        <Fieldset>
          <FieldsetTitle>
            <Label htmlFor={`${uid}-street-address`}>Guardian's address</Label>
          </FieldsetTitle>
          <Input
            id={`${uid}-street-address`}
            type="text"
            disabled={isFormDisabled}
            value={formState.street_address}
            onChange={(event) => updateForm({ street_address: event.target.value })}
          />
          <FieldsetDescription>A physical address, not a PO box.</FieldsetDescription>
        </Fieldset>

        {/* Every field here is prefixed "Guardian's" on purpose: the seller's OWN city, state and ZIP
            sit in Account details directly above, and two identically labelled fields on one page
            leave the seller guessing which person each belongs to. */}
        <div className="grid gap-5 md:auto-cols-fr md:grid-flow-col">
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-city`}>Guardian's city</Label>
            </FieldsetTitle>
            <Input
              id={`${uid}-city`}
              type="text"
              disabled={isFormDisabled}
              value={formState.city}
              onChange={(event) => updateForm({ city: event.target.value })}
            />
          </Fieldset>
          {states.length > 0 ? (
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-state`}>Guardian's state</Label>
              </FieldsetTitle>
              <Select
                id={`${uid}-state`}
                disabled={isFormDisabled}
                value={formState.state}
                onChange={(event) => updateForm({ state: event.target.value })}
              >
                <option value="">Select a state</option>
                {states.map((state) => (
                  <option key={state.code} value={state.code}>
                    {state.name}
                  </option>
                ))}
              </Select>
            </Fieldset>
          ) : null}
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-zip-code`}>Guardian's ZIP code</Label>
            </FieldsetTitle>
            <Input
              id={`${uid}-zip-code`}
              type="text"
              disabled={isFormDisabled}
              value={formState.zip_code}
              onChange={(event) => updateForm({ zip_code: event.target.value })}
            />
          </Fieldset>
        </div>

        <Fieldset>
          <FieldsetTitle>
            <Label htmlFor={`${uid}-individual-tax-id`}>
              {sellerCountry === "US" ? "Guardian's Social Security number" : "Guardian's personal ID number"}
            </Label>
          </FieldsetTitle>
          <Input
            id={`${uid}-individual-tax-id`}
            type="text"
            disabled={isFormDisabled}
            placeholder={existing?.has_individual_tax_id ? "•••••••••" : ""}
            value={formState.individual_tax_id}
            onChange={(event) => updateForm({ individual_tax_id: event.target.value })}
          />
          <FieldsetDescription>
            {existing?.has_individual_tax_id
              ? "On file. Enter a new number only if you need to replace it."
              : "Our payment partner verifies your guardian against this number. It is encrypted and we never see it."}
          </FieldsetDescription>
        </Fieldset>

        <Fieldset>
          <Label className="flex items-start gap-2">
            <Checkbox
              checked={formState.accept_terms}
              disabled={isFormDisabled || existing?.accepted_terms}
              onChange={(event) => updateForm({ accept_terms: event.target.checked })}
            />
            <span>
              My guardian has read and accepts the{" "}
              <a href="https://stripe.com/legal/connect-account" target="_blank" rel="noreferrer">
                Stripe Connected Account Agreement
              </a>
              .
            </span>
          </Label>
          <FieldsetDescription>
            Your guardian has to accept this themselves — our payment partner requires their agreement, not yours.
          </FieldsetDescription>
        </Fieldset>

        <div>
          <Button
            color="primary"
            type="button"
            onClick={() => void handleSubmit()}
            disabled={isSaving || isFormDisabled}
          >
            {isSaving ? "Saving…" : existing ? "Save guardian" : "Add guardian"}
          </Button>
        </div>
      </div>
    </section>
  );
};

export default LegalGuardianSection;
