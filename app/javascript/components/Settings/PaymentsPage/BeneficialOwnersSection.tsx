import * as React from "react";
import typia from "typia";

import { request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Checkbox } from "$app/components/ui/Checkbox";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { Select } from "$app/components/ui/Select";
import { Sheet, SheetHeader } from "$app/components/ui/Sheet";

const DEFAULT_TITLE = "Director";

const KANA_NAME_REGEX = /^[゠-ヿㇰ-ㇿ･-ﾟ\s\-.]*$/u;
const KANA_ADDRESS_REGEX = /^[゠-ヿㇰ-ㇿ･-ﾟ\p{Script=Latin}\d\s\-.]*$/u;
const HAS_KATAKANA = /[゠-ヿㇰ-ㇿ･-ﾟ]/u;

type BeneficialOwner = {
  id: string;
  first_name: string | null;
  last_name: string | null;
  email: string | null;
  phone: string | null;
  dob: { day: number | null; month: number | null; year: number | null } | null;
  address: {
    line1?: string | null;
    line2?: string | null;
    city?: string | null;
    state?: string | null;
    postal_code?: string | null;
    country?: string | null;
  };
  address_kanji?: {
    line1?: string | null;
    town?: string | null;
    state?: string | null;
    postal_code?: string | null;
    country?: string | null;
  };
  address_kana?: {
    line1?: string | null;
    town?: string | null;
    state?: string | null;
    postal_code?: string | null;
    country?: string | null;
  };
  first_name_kanji?: string | null;
  last_name_kanji?: string | null;
  first_name_kana?: string | null;
  last_name_kana?: string | null;
  relationship: {
    owner: boolean;
    director: boolean;
    executive: boolean;
    representative: boolean;
    title: string | null;
    percent_ownership: number | null;
  };
  id_number_provided: boolean;
  ssn_last_4_provided: boolean;
  nationality: string | null;
  verification_status: string | null;
  requirements_currently_due: string[];
};

const NATIONALITY_REQUIRED_COUNTRIES = ["AE", "SG", "BD", "PK"];

type FormState = {
  first_name: string;
  last_name: string;
  email: string;
  phone: string;
  dob_day: string;
  dob_month: string;
  dob_year: string;
  address_line1: string;
  address_city: string;
  address_state: string;
  address_postal_code: string;
  address_country: string;
  first_name_kanji: string;
  last_name_kanji: string;
  first_name_kana: string;
  last_name_kana: string;
  address_building_number: string;
  address_building_number_kana: string;
  address_street_address_kanji: string;
  address_street_address_kana: string;
  id_number: string;
  nationality: string;
  title: string;
  percent_ownership: string;
  owner: boolean;
  director: boolean;
  executive: boolean;
};

type StatesByCountry = {
  us: { code: string; name: string }[];
  ca: { code: string; name: string }[];
  au: { code: string; name: string }[];
  mx: { code: string; name: string }[];
  ae: { code: string; name: string }[];
  ir: { code: string; name: string }[];
  br: { code: string; name: string }[];
  jp: { value: string; label: string; kana: string }[];
};

const STATE_LIST_LABEL: Record<string, string> = {
  US: "State",
  CA: "Province",
  AU: "State",
  MX: "State",
  AE: "Emirate",
  BR: "State",
  JP: "Prefecture",
  IE: "County",
};

type TaxIdConfig = {
  label: string;
  placeholder: string;
  minLength?: number;
  maxLength?: number;
  idSuffix: string;
};

const FALLBACK_TAX_ID_CONFIG: TaxIdConfig = {
  label: "Personal ID number",
  placeholder: "Government-issued ID number",
  idSuffix: "personal-id-number",
};

const SSN_LAST_4_CONFIG: TaxIdConfig = {
  label: "Last 4 digits of Social Security number",
  placeholder: "8888",
  minLength: 4,
  maxLength: 4,
  idSuffix: "social-security-number",
};

const PERSONAL_ID_NUMBER_CONFIG: TaxIdConfig = {
  label: "Personal ID number",
  placeholder: "Government-issued ID number",
  idSuffix: "personal-id-number",
};

const TAX_ID_CONFIGS: Record<string, TaxIdConfig> = {
  US: SSN_LAST_4_CONFIG,
  CA: {
    label: "Social Insurance Number",
    placeholder: "•••••••••",
    minLength: 9,
    maxLength: 9,
    idSuffix: "social-insurance-number",
  },
  HK: {
    label: "Hong Kong ID Number",
    placeholder: "123456789",
    minLength: 8,
    maxLength: 9,
    idSuffix: "hong-kong-id-number",
  },
  SG: {
    label: "NRIC number / FIN",
    placeholder: "123456789",
    minLength: 9,
    maxLength: 9,
    idSuffix: "singapore-id-number",
  },
  AE: { label: "Emirates ID", placeholder: "123456789123456", minLength: 15, maxLength: 15, idSuffix: "uae-id-number" },
  MX: {
    label: "Personal RFC",
    placeholder: "1234567891234",
    minLength: 13,
    maxLength: 13,
    idSuffix: "mexico-id-number",
  },
  KZ: {
    label: "Individual identification number (IIN)",
    placeholder: "123456789",
    minLength: 9,
    maxLength: 12,
    idSuffix: "kazakhstan-id-number",
  },
  AR: { label: "CUIL", placeholder: "12-12345678-1", minLength: 13, maxLength: 13, idSuffix: "argentina-id-number" },
  PE: { label: "DNI number", placeholder: "12345678-9", minLength: 10, maxLength: 10, idSuffix: "peru-id-number" },
  PK: {
    label: "National Identity Card Number (SNIC or CNIC)",
    placeholder: "•••••••••",
    minLength: 13,
    maxLength: 13,
    idSuffix: "snic",
  },
  CR: {
    label: "Tax Identification Number",
    placeholder: "1234567890",
    minLength: 9,
    maxLength: 12,
    idSuffix: "costa-rica-id-number",
  },
  CL: {
    label: "Rol Único Tributario (RUT)",
    placeholder: "123456789",
    minLength: 8,
    maxLength: 9,
    idSuffix: "chile-id-number",
  },
  CO: {
    label: "Cédula de Ciudadanía (CC)",
    placeholder: "1.123.123.123",
    minLength: 13,
    maxLength: 13,
    idSuffix: "colombia-id-number",
  },
  UY: {
    label: "Cédula de Identidad (CI)",
    placeholder: "1.123.123-1",
    minLength: 11,
    maxLength: 11,
    idSuffix: "uruguay-id-number",
  },
  DO: {
    label: "Cédula de identidad y electoral (CIE)",
    placeholder: "123-1234567-1",
    minLength: 13,
    maxLength: 13,
    idSuffix: "dominican-republic-id-number",
  },
  BO: {
    label: "Cédula de Identidad (CI)",
    placeholder: "12345678",
    minLength: 8,
    maxLength: 8,
    idSuffix: "bolivia-id-number",
  },
  PY: {
    label: "Cédula de Identidad (CI)",
    placeholder: "1234567",
    minLength: 7,
    maxLength: 7,
    idSuffix: "paraguay-id-number",
  },
  BD: {
    label: "Personal ID number",
    placeholder: "123456789",
    minLength: 1,
    maxLength: 20,
    idSuffix: "bangladesh-id-number",
  },
  MZ: {
    label: "Mozambique Taxpayer Single ID Number (NUIT)",
    placeholder: "123456789",
    minLength: 9,
    maxLength: 9,
    idSuffix: "mozambique-id-number",
  },
  GT: {
    label: "Número de Identificación Tributaria (NIT)",
    placeholder: "1234567-8",
    minLength: 8,
    maxLength: 12,
    idSuffix: "guatemala-id-number",
  },
  BR: {
    label: "Cadastro de Pessoas Físicas (CPF)",
    placeholder: "123.456.789-00",
    minLength: 11,
    maxLength: 14,
    idSuffix: "brazil-id-number",
  },
};

const taxIdConfigFor = (country: string | null): TaxIdConfig => {
  if (!country) return FALLBACK_TAX_ID_CONFIG;
  return TAX_ID_CONFIGS[country] ?? FALLBACK_TAX_ID_CONFIG;
};

const maskedTaxIdValue = (placeholder: string): string => placeholder.replace(/[a-zA-Z0-9]/gu, "•");

const blankFormState = (defaultCountry: string | null): FormState => ({
  first_name: "",
  last_name: "",
  email: "",
  phone: "",
  dob_day: "",
  dob_month: "",
  dob_year: "",
  address_line1: "",
  address_city: "",
  address_state: "",
  address_postal_code: "",
  address_country: defaultCountry ?? "",
  first_name_kanji: "",
  last_name_kanji: "",
  first_name_kana: "",
  last_name_kana: "",
  address_building_number: "",
  address_building_number_kana: "",
  address_street_address_kanji: "",
  address_street_address_kana: "",
  id_number: "",
  nationality: "",
  title: DEFAULT_TITLE,
  percent_ownership: "",
  owner: false,
  director: true,
  executive: false,
});

const ownerToFormState = (owner: BeneficialOwner, defaultCountry: string | null): FormState => ({
  first_name: owner.first_name ?? "",
  last_name: owner.last_name ?? "",
  email: owner.email ?? "",
  phone: owner.phone ?? "",
  dob_day: owner.dob?.day != null ? String(owner.dob.day) : "",
  dob_month: owner.dob?.month != null ? String(owner.dob.month) : "",
  dob_year: owner.dob?.year != null ? String(owner.dob.year) : "",
  address_line1: owner.address.line1 ?? "",
  address_city: owner.address.city ?? "",
  address_state: owner.address.state ?? owner.address_kanji?.state ?? "",
  address_postal_code: owner.address.postal_code ?? owner.address_kanji?.postal_code ?? "",
  address_country: owner.address.country ?? owner.address_kanji?.country ?? defaultCountry ?? "",
  first_name_kanji: owner.first_name_kanji ?? "",
  last_name_kanji: owner.last_name_kanji ?? "",
  first_name_kana: owner.first_name_kana ?? "",
  last_name_kana: owner.last_name_kana ?? "",
  address_building_number: owner.address_kanji?.line1 ?? "",
  address_building_number_kana: owner.address_kana?.line1 ?? "",
  address_street_address_kanji: owner.address_kanji?.town ?? "",
  address_street_address_kana: owner.address_kana?.town ?? "",
  id_number: "",
  nationality: owner.nationality ?? "",
  title: owner.relationship.title ?? DEFAULT_TITLE,
  percent_ownership: owner.relationship.percent_ownership != null ? String(owner.relationship.percent_ownership) : "",
  owner: owner.relationship.owner,
  director: owner.relationship.director,
  executive: owner.relationship.executive,
});

const formStatePayload = (state: FormState) => ({
  beneficial_owner: {
    first_name: state.first_name,
    last_name: state.last_name,
    email: state.email,
    phone: state.phone,
    title: state.title,
    owner: state.owner,
    director: state.director,
    executive: state.executive,
    percent_ownership: state.percent_ownership === "" ? null : Number(state.percent_ownership),
    id_number: state.id_number,
    nationality: state.nationality,
    first_name_kanji: state.first_name_kanji,
    last_name_kanji: state.last_name_kanji,
    first_name_kana: state.first_name_kana,
    last_name_kana: state.last_name_kana,
    dob: { day: state.dob_day, month: state.dob_month, year: state.dob_year },
    address: {
      line1: state.address_line1,
      city: state.address_city,
      state: state.address_state,
      postal_code: state.address_postal_code,
      country: state.address_country,
      building_number: state.address_building_number,
      building_number_kana: state.address_building_number_kana,
      street_address_kanji: state.address_street_address_kanji,
      street_address_kana: state.address_street_address_kana,
    },
  },
});

const representativePayload = (state: FormState) => ({
  beneficial_owner: {
    title: state.title,
    owner: state.owner,
    director: state.director,
    executive: state.executive,
    percent_ownership: state.percent_ownership === "" ? null : Number(state.percent_ownership),
  },
});

const fullName = (owner: BeneficialOwner) =>
  [owner.first_name, owner.last_name].filter(Boolean).join(" ").trim() || "Unnamed person";

const ownerRole = (owner: BeneficialOwner) => {
  const roles = [
    owner.relationship.director ? "Director" : null,
    owner.relationship.owner ? "Owner" : null,
    owner.relationship.executive ? "Executive" : null,
  ].filter(Boolean);
  return roles.join(", ") || "—";
};

type EditState = { mode: "create" } | { mode: "edit"; owner: BeneficialOwner };

const BeneficialOwnersSection = ({
  countries,
  states,
  defaultCountry,
  minDobYear,
  isFormDisabled,
}: {
  countries: Record<string, string>;
  states: StatesByCountry;
  defaultCountry: string | null;
  minDobYear: number;
  isFormDisabled: boolean;
}) => {
  const [owners, setOwners] = React.useState<BeneficialOwner[]>([]);
  const [isLoading, setIsLoading] = React.useState(true);
  const [loadError, setLoadError] = React.useState<string | null>(null);
  const [editState, setEditState] = React.useState<EditState | null>(null);
  const [formState, setFormState] = React.useState<FormState>(() => blankFormState(defaultCountry));
  const [formError, setFormError] = React.useState<string | null>(null);
  const formErrorRef = React.useRef<HTMLDivElement | null>(null);

  React.useEffect(() => {
    if (formError) formErrorRef.current?.scrollIntoView({ behavior: "smooth", block: "start" });
  }, [formError]);
  const [isSaving, setIsSaving] = React.useState(false);
  const [pendingDeletion, setPendingDeletion] = React.useState<BeneficialOwner | null>(null);
  const [isDeleting, setIsDeleting] = React.useState(false);
  const [isEditingTaxId, setIsEditingTaxId] = React.useState(false);
  const [useGovernmentIdForUs, setUseGovernmentIdForUs] = React.useState(false);
  const uid = React.useId();

  const refresh = React.useCallback(async () => {
    setIsLoading(true);
    setLoadError(null);
    try {
      const response = await request({
        method: "GET",
        url: Routes.settings_beneficial_owners_path(),
        accept: "json",
      });
      if (!response.ok) throw new ResponseError(`Request failed (${response.status})`);
      const data = typia.assert<{ beneficial_owners: BeneficialOwner[] }>(await response.json());
      setOwners(data.beneficial_owners);
    } catch (error) {
      setLoadError(error instanceof Error ? error.message : "Couldn't load beneficial owners.");
    } finally {
      setIsLoading(false);
    }
  }, []);

  React.useEffect(() => {
    void refresh();
  }, [refresh]);

  const openCreate = () => {
    setEditState({ mode: "create" });
    setFormState(blankFormState(defaultCountry));
    setFormError(null);
    setIsEditingTaxId(true);
    setUseGovernmentIdForUs(false);
  };

  const openEdit = (owner: BeneficialOwner) => {
    setEditState({ mode: "edit", owner });
    setFormState(ownerToFormState(owner, defaultCountry));
    setFormError(null);
    setIsEditingTaxId(!(owner.id_number_provided || owner.ssn_last_4_provided));
    setUseGovernmentIdForUs(owner.id_number_provided && !owner.ssn_last_4_provided);
  };

  const closeSheet = () => {
    if (isSaving) return;
    setEditState(null);
    setFormError(null);
  };

  const updateForm = (patch: Partial<FormState>) => setFormState((prev) => ({ ...prev, ...patch }));

  const validateJpKanaFields = (): string | null => {
    if (editState?.mode === "edit" && editState.owner.relationship.representative) return null;
    if (defaultCountry === "JP") {
      if (!KANA_NAME_REGEX.test(formState.first_name_kana)) {
        return "First name (Kana) may only contain katakana characters, spaces, dashes, and dots.";
      }
      if (!KANA_NAME_REGEX.test(formState.last_name_kana)) {
        return "Last name (Kana) may only contain katakana characters, spaces, dashes, and dots.";
      }
    }
    if (formState.address_country === "JP") {
      if (!KANA_ADDRESS_REGEX.test(formState.address_building_number_kana)) {
        return "Block / Building number (Kana) may only contain katakana, latin characters, digits, spaces, dashes, and dots.";
      }
      if (!KANA_ADDRESS_REGEX.test(formState.address_street_address_kana)) {
        return "Town/Cho-me (Kana) may only contain katakana, latin characters, digits, spaces, dashes, and dots.";
      }
      if (!HAS_KATAKANA.test(formState.address_street_address_kana)) {
        return "Town/Cho-me (Kana) must include katakana characters.";
      }
    }
    return null;
  };

  const handleSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!editState) return;
    const kanaError = validateJpKanaFields();
    if (kanaError) {
      setFormError(kanaError);
      return;
    }
    setIsSaving(true);
    setFormError(null);
    try {
      const isEdit = editState.mode === "edit";
      const isRepresentative = isEdit && editState.owner.relationship.representative;
      const response = await request({
        method: isEdit ? "PUT" : "POST",
        url: isEdit
          ? Routes.settings_beneficial_owner_path(editState.owner.id)
          : Routes.settings_beneficial_owners_path(),
        accept: "json",
        data: isRepresentative ? representativePayload(formState) : formStatePayload(formState),
      });
      if (!response.ok) {
        const body = typia.assert<{ error?: string }>(await response.json().catch(() => ({})));
        throw new ResponseError(body.error || `Request failed (${response.status})`);
      }
      showAlert(isEdit ? "Beneficial owner updated." : "Beneficial owner added.", "success");
      setEditState(null);
      await refresh();
    } catch (error) {
      setFormError(error instanceof Error ? error.message : "Couldn't save beneficial owner.");
    } finally {
      setIsSaving(false);
    }
  };

  const handleConfirmDelete = async () => {
    if (!pendingDeletion) return;
    setIsDeleting(true);
    try {
      const response = await request({
        method: "DELETE",
        url: Routes.settings_beneficial_owner_path(pendingDeletion.id),
        accept: "json",
      });
      if (!response.ok) {
        const body = typia.assert<{ error?: string }>(await response.json().catch(() => ({})));
        throw new ResponseError(body.error || `Request failed (${response.status})`);
      }
      showAlert("Beneficial owner removed.", "success");
      setPendingDeletion(null);
      await refresh();
    } catch (error) {
      showAlert(error instanceof Error ? error.message : "Couldn't remove beneficial owner.", "error");
    } finally {
      setIsDeleting(false);
    }
  };

  const sortedOwners = React.useMemo(
    () => [...owners].sort((a, b) => Number(b.relationship.representative) - Number(a.relationship.representative)),
    [owners],
  );

  return (
    <section className="grid gap-4">
      <header className="grid gap-2">
        <h3 className="text-lg font-bold">Beneficial owners</h3>
        <p className="text-muted">
          Add the directors and owners of your business who hold shares or significant control. Your representative
          appears first — identity and address are managed in <strong>Account details</strong> above; only their
          ownership split and role are editable here.
        </p>
      </header>

      {loadError ? <Alert variant="danger">{loadError}</Alert> : null}

      {isLoading ? (
        <p className="text-muted">Loading…</p>
      ) : sortedOwners.length === 0 ? (
        <p className="text-muted">No beneficial owners on file.</p>
      ) : (
        <ul className="grid list-none gap-2 pl-0" aria-label="Beneficial owners">
          {sortedOwners.map((owner) => {
            const isRep = owner.relationship.representative;
            return (
              <li
                key={owner.id}
                className="grid gap-3 rounded-md border border-border p-4 sm:flex sm:flex-wrap sm:items-center sm:gap-4"
              >
                <div className="grid grow gap-1">
                  <strong>
                    {fullName(owner)}
                    {isRep ? (
                      <span className="ml-2 inline-block rounded-full border border-border bg-muted/30 px-2 py-0.5 text-xs font-normal">
                        Representative
                      </span>
                    ) : null}
                  </strong>
                  <span className="text-sm text-muted">
                    {ownerRole(owner)}
                    {owner.relationship.percent_ownership != null ? ` · ${owner.relationship.percent_ownership}%` : ""}
                    {owner.relationship.title ? ` · ${owner.relationship.title}` : ""}
                  </span>
                  {owner.requirements_currently_due.length > 0 ? (
                    <span className="text-sm text-warning">
                      Stripe needs: {owner.requirements_currently_due.join(", ")}
                    </span>
                  ) : null}
                </div>
                <div className="flex flex-wrap gap-2">
                  <Button
                    color="primary"
                    onClick={() => openEdit(owner)}
                    disabled={isFormDisabled}
                    aria-label={`Edit ${fullName(owner)}`}
                  >
                    Edit
                  </Button>
                  {isRep ? null : (
                    <Button
                      color="danger"
                      onClick={() => setPendingDeletion(owner)}
                      disabled={isFormDisabled}
                      aria-label={`Remove ${fullName(owner)}`}
                    >
                      Remove
                    </Button>
                  )}
                </div>
              </li>
            );
          })}
        </ul>
      )}

      <div>
        <Button color="primary" onClick={openCreate} disabled={isFormDisabled || isLoading}>
          Add beneficial owner
        </Button>
      </div>

      {editState ? (
        <Sheet open onOpenChange={(open) => (!open ? closeSheet() : null)} modal>
          <SheetHeader>
            <h3 className="text-lg font-bold">
              {editState.mode === "edit"
                ? editState.owner.relationship.representative
                  ? "Edit representative ownership"
                  : "Edit beneficial owner"
                : "Add beneficial owner"}
            </h3>
          </SheetHeader>
          <form onSubmit={(event) => void handleSubmit(event)} className="grid gap-4">
            <div ref={formErrorRef}>{formError ? <Alert variant="danger">{formError}</Alert> : null}</div>

            {editState.mode === "edit" && editState.owner.relationship.representative ? (
              <Alert variant="info">
                Identity, date of birth, address, and tax ID for the representative are managed in{" "}
                <strong>Account details</strong> above. Only ownership and role are editable here.
              </Alert>
            ) : null}

            {editState.mode === "edit" && editState.owner.relationship.representative ? null : (
              <>
                <div
                  style={{
                    display: "grid",
                    gap: "var(--spacer-5)",
                    gridAutoFlow: "column",
                    gridAutoColumns: "1fr",
                  }}
                >
                  <Fieldset>
                    <FieldsetTitle>
                      <Label htmlFor={`${uid}-first-name`}>First name</Label>
                    </FieldsetTitle>
                    <Input
                      id={`${uid}-first-name`}
                      type="text"
                      required
                      disabled={isFormDisabled}
                      value={formState.first_name}
                      onChange={(event) => updateForm({ first_name: event.target.value })}
                    />
                  </Fieldset>
                  <Fieldset>
                    <FieldsetTitle>
                      <Label htmlFor={`${uid}-last-name`}>Last name</Label>
                    </FieldsetTitle>
                    <Input
                      id={`${uid}-last-name`}
                      type="text"
                      required
                      disabled={isFormDisabled}
                      value={formState.last_name}
                      onChange={(event) => updateForm({ last_name: event.target.value })}
                    />
                  </Fieldset>
                </div>

                {defaultCountry === "JP" ? (
                  <>
                    <div
                      style={{
                        display: "grid",
                        gap: "var(--spacer-5)",
                        gridAutoFlow: "column",
                        gridAutoColumns: "1fr",
                      }}
                    >
                      <Fieldset>
                        <FieldsetTitle>
                          <Label htmlFor={`${uid}-first-name-kanji`}>First name (Kanji)</Label>
                        </FieldsetTitle>
                        <Input
                          id={`${uid}-first-name-kanji`}
                          type="text"
                          required
                          disabled={isFormDisabled}
                          value={formState.first_name_kanji}
                          onChange={(event) => updateForm({ first_name_kanji: event.target.value })}
                        />
                      </Fieldset>
                      <Fieldset>
                        <FieldsetTitle>
                          <Label htmlFor={`${uid}-last-name-kanji`}>Last name (Kanji)</Label>
                        </FieldsetTitle>
                        <Input
                          id={`${uid}-last-name-kanji`}
                          type="text"
                          required
                          disabled={isFormDisabled}
                          value={formState.last_name_kanji}
                          onChange={(event) => updateForm({ last_name_kanji: event.target.value })}
                        />
                      </Fieldset>
                    </div>
                    <div
                      style={{
                        display: "grid",
                        gap: "var(--spacer-5)",
                        gridAutoFlow: "column",
                        gridAutoColumns: "1fr",
                      }}
                    >
                      <Fieldset>
                        <FieldsetTitle>
                          <Label htmlFor={`${uid}-first-name-kana`}>First name (Kana)</Label>
                        </FieldsetTitle>
                        <Input
                          id={`${uid}-first-name-kana`}
                          type="text"
                          required
                          placeholder="カタカナ"
                          disabled={isFormDisabled}
                          value={formState.first_name_kana}
                          onChange={(event) => updateForm({ first_name_kana: event.target.value })}
                        />
                      </Fieldset>
                      <Fieldset>
                        <FieldsetTitle>
                          <Label htmlFor={`${uid}-last-name-kana`}>Last name (Kana)</Label>
                        </FieldsetTitle>
                        <Input
                          id={`${uid}-last-name-kana`}
                          type="text"
                          required
                          placeholder="カタカナ"
                          disabled={isFormDisabled}
                          value={formState.last_name_kana}
                          onChange={(event) => updateForm({ last_name_kana: event.target.value })}
                        />
                      </Fieldset>
                    </div>
                  </>
                ) : null}

                <div
                  style={{
                    display: "grid",
                    gap: "var(--spacer-5)",
                    gridAutoFlow: "column",
                    gridAutoColumns: "1fr",
                  }}
                >
                  <Fieldset>
                    <FieldsetTitle>
                      <Label htmlFor={`${uid}-email`}>Email</Label>
                    </FieldsetTitle>
                    <Input
                      id={`${uid}-email`}
                      type="email"
                      required
                      disabled={isFormDisabled}
                      value={formState.email}
                      onChange={(event) => updateForm({ email: event.target.value })}
                    />
                  </Fieldset>
                  <Fieldset>
                    <FieldsetTitle>
                      <Label htmlFor={`${uid}-phone`}>Phone number</Label>
                    </FieldsetTitle>
                    <Input
                      id={`${uid}-phone`}
                      type="tel"
                      required
                      disabled={isFormDisabled}
                      placeholder="+447700900001"
                      value={formState.phone}
                      onChange={(event) => updateForm({ phone: event.target.value })}
                    />
                  </Fieldset>
                </div>

                <Fieldset>
                  <FieldsetTitle>
                    <Label>Date of birth</Label>
                  </FieldsetTitle>
                  <div
                    style={{
                      display: "grid",
                      gap: "var(--spacer-5)",
                      gridAutoFlow: "column",
                      gridAutoColumns: "1fr",
                    }}
                  >
                    <Fieldset>
                      <Select
                        id={`${uid}-dob-month`}
                        disabled={isFormDisabled}
                        required
                        aria-label="Month"
                        value={formState.dob_month || ""}
                        onChange={(event) => updateForm({ dob_month: event.target.value })}
                      >
                        <option value="" disabled>
                          Month
                        </option>
                        {Array.from({ length: 12 }, (_, i) => i + 1).map((month) => (
                          <option key={month} value={month}>
                            {new Date(2000, month - 1, 1).toLocaleString("en-US", { month: "long" })}
                          </option>
                        ))}
                      </Select>
                    </Fieldset>
                    <Fieldset>
                      <Select
                        id={`${uid}-dob-day`}
                        disabled={isFormDisabled}
                        required
                        aria-label="Day"
                        value={formState.dob_day || ""}
                        onChange={(event) => updateForm({ dob_day: event.target.value })}
                      >
                        <option value="" disabled>
                          Day
                        </option>
                        {Array.from({ length: 31 }, (_, i) => i + 1).map((day) => (
                          <option key={day} value={day}>
                            {day}
                          </option>
                        ))}
                      </Select>
                    </Fieldset>
                    <Fieldset>
                      <Select
                        id={`${uid}-dob-year`}
                        disabled={isFormDisabled}
                        required
                        aria-label="Year"
                        value={formState.dob_year || ""}
                        onChange={(event) => updateForm({ dob_year: event.target.value })}
                      >
                        <option value="" disabled>
                          Year
                        </option>
                        {Array.from({ length: minDobYear - 1900 }, (_, i) => i + 1900).map((year) => (
                          <option key={year} value={year}>
                            {year}
                          </option>
                        ))}
                      </Select>
                    </Fieldset>
                  </div>
                </Fieldset>

                {formState.address_country === "JP" ? (
                  <>
                    <div
                      style={{
                        display: "grid",
                        gap: "var(--spacer-5)",
                        gridAutoFlow: "column",
                        gridAutoColumns: "1fr",
                        alignItems: "end",
                      }}
                    >
                      <Fieldset>
                        <FieldsetTitle>
                          <Label htmlFor={`${uid}-building-number`}>Block / Building number</Label>
                        </FieldsetTitle>
                        <Input
                          id={`${uid}-building-number`}
                          type="text"
                          required
                          placeholder="1-1"
                          disabled={isFormDisabled}
                          value={formState.address_building_number}
                          onChange={(event) => updateForm({ address_building_number: event.target.value })}
                        />
                      </Fieldset>
                      <Fieldset>
                        <FieldsetTitle>
                          <Label htmlFor={`${uid}-building-number-kana`}>Block / Building number (Kana)</Label>
                        </FieldsetTitle>
                        <Input
                          id={`${uid}-building-number-kana`}
                          type="text"
                          required
                          placeholder="1-1"
                          disabled={isFormDisabled}
                          value={formState.address_building_number_kana}
                          onChange={(event) => updateForm({ address_building_number_kana: event.target.value })}
                        />
                      </Fieldset>
                    </div>
                    <div
                      style={{
                        display: "grid",
                        gap: "var(--spacer-5)",
                        gridAutoFlow: "column",
                        gridAutoColumns: "1fr",
                      }}
                    >
                      <Fieldset>
                        <FieldsetTitle>
                          <Label htmlFor={`${uid}-street-address-kanji`}>Town/Cho-me (Kanji)</Label>
                        </FieldsetTitle>
                        <Input
                          id={`${uid}-street-address-kanji`}
                          type="text"
                          required
                          placeholder="千代田"
                          disabled={isFormDisabled}
                          value={formState.address_street_address_kanji}
                          onChange={(event) => updateForm({ address_street_address_kanji: event.target.value })}
                        />
                      </Fieldset>
                      <Fieldset>
                        <FieldsetTitle>
                          <Label htmlFor={`${uid}-street-address-kana`}>Town/Cho-me (Kana)</Label>
                        </FieldsetTitle>
                        <Input
                          id={`${uid}-street-address-kana`}
                          type="text"
                          required
                          placeholder="チヨダ"
                          disabled={isFormDisabled}
                          value={formState.address_street_address_kana}
                          onChange={(event) => updateForm({ address_street_address_kana: event.target.value })}
                        />
                      </Fieldset>
                    </div>
                  </>
                ) : (
                  <Fieldset>
                    <FieldsetTitle>
                      <Label htmlFor={`${uid}-address-line1`}>Address</Label>
                    </FieldsetTitle>
                    <Input
                      id={`${uid}-address-line1`}
                      type="text"
                      required
                      disabled={isFormDisabled}
                      value={formState.address_line1}
                      onChange={(event) => updateForm({ address_line1: event.target.value })}
                    />
                  </Fieldset>
                )}

                <div
                  style={{
                    display: "grid",
                    gap: "var(--spacer-5)",
                    gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
                  }}
                >
                  {formState.address_country === "JP" ? null : (
                    <Fieldset>
                      <FieldsetTitle>
                        <Label htmlFor={`${uid}-address-city`}>City</Label>
                      </FieldsetTitle>
                      <Input
                        id={`${uid}-address-city`}
                        type="text"
                        required
                        disabled={isFormDisabled}
                        value={formState.address_city}
                        onChange={(event) => updateForm({ address_city: event.target.value })}
                      />
                    </Fieldset>
                  )}
                  {(() => {
                    const country = formState.address_country;
                    const label = STATE_LIST_LABEL[country] ?? "State / region";
                    const stateList =
                      country === "US"
                        ? states.us
                        : country === "CA"
                          ? states.ca
                          : country === "AU"
                            ? states.au
                            : country === "MX"
                              ? states.mx
                              : country === "AE"
                                ? states.ae
                                : country === "IE"
                                  ? states.ir
                                  : country === "BR"
                                    ? states.br
                                    : null;
                    return (
                      <Fieldset>
                        <FieldsetTitle>
                          <Label htmlFor={`${uid}-address-state`}>{label}</Label>
                        </FieldsetTitle>
                        {stateList ? (
                          <Select
                            id={`${uid}-address-state`}
                            required
                            disabled={isFormDisabled}
                            value={formState.address_state || ""}
                            onChange={(event) => updateForm({ address_state: event.target.value })}
                          >
                            <option value="" disabled>
                              {label}
                            </option>
                            {stateList.map((entry) => (
                              <option key={entry.code} value={entry.code}>
                                {entry.name}
                              </option>
                            ))}
                          </Select>
                        ) : country === "JP" ? (
                          <Select
                            id={`${uid}-address-state`}
                            required
                            disabled={isFormDisabled}
                            value={formState.address_state || ""}
                            onChange={(event) => updateForm({ address_state: event.target.value })}
                          >
                            <option value="" disabled>
                              {label}
                            </option>
                            {states.jp.map((entry) => (
                              <option key={entry.value} value={entry.value}>
                                {entry.label}
                              </option>
                            ))}
                          </Select>
                        ) : (
                          <Input
                            id={`${uid}-address-state`}
                            type="text"
                            disabled={isFormDisabled}
                            value={formState.address_state}
                            onChange={(event) => updateForm({ address_state: event.target.value })}
                          />
                        )}
                      </Fieldset>
                    );
                  })()}
                  {formState.address_country === "BW" ? null : (
                    <Fieldset>
                      <FieldsetTitle>
                        <Label htmlFor={`${uid}-address-postal-code`}>
                          {formState.address_country === "US" ? "ZIP code" : "Postal code"}
                        </Label>
                      </FieldsetTitle>
                      <Input
                        id={`${uid}-address-postal-code`}
                        type="text"
                        required
                        disabled={isFormDisabled}
                        value={formState.address_postal_code}
                        onChange={(event) => updateForm({ address_postal_code: event.target.value })}
                      />
                    </Fieldset>
                  )}
                </div>

                <Fieldset>
                  <FieldsetTitle>
                    <Label htmlFor={`${uid}-address-country`}>Country</Label>
                  </FieldsetTitle>
                  <Select
                    id={`${uid}-address-country`}
                    disabled={isFormDisabled}
                    required
                    value={formState.address_country || ""}
                    onChange={(event) =>
                      updateForm({
                        address_country: event.target.value,
                        address_line1: "",
                        address_city: "",
                        address_state: "",
                        address_postal_code: "",
                        address_building_number: "",
                        address_building_number_kana: "",
                        address_street_address_kanji: "",
                        address_street_address_kana: "",
                      })
                    }
                  >
                    <option value="" disabled>
                      Country
                    </option>
                    {Object.entries(countries).map(([code, name]) => (
                      <option key={code} value={code} disabled={name.includes("(not supported)")}>
                        {name}
                      </option>
                    ))}
                  </Select>
                </Fieldset>

                {NATIONALITY_REQUIRED_COUNTRIES.includes(defaultCountry ?? "") ? (
                  <Fieldset>
                    <FieldsetTitle>
                      <Label htmlFor={`${uid}-nationality`}>Nationality</Label>
                    </FieldsetTitle>
                    <Select
                      id={`${uid}-nationality`}
                      required
                      disabled={isFormDisabled}
                      value={formState.nationality || ""}
                      onChange={(event) => updateForm({ nationality: event.target.value })}
                    >
                      <option value="" disabled>
                        Nationality
                      </option>
                      {Object.entries(countries).map(([code, name]) => (
                        <option key={code} value={code} disabled={name.includes("(not supported)")}>
                          {name}
                        </option>
                      ))}
                    </Select>
                  </Fieldset>
                ) : null}

                {(() => {
                  const isUs = defaultCountry === "US";
                  const taxIdConfig =
                    isUs && useGovernmentIdForUs ? PERSONAL_ID_NUMBER_CONFIG : taxIdConfigFor(defaultCountry);
                  const hasTaxIdOnFile =
                    editState.mode === "edit" &&
                    (editState.owner.id_number_provided || editState.owner.ssn_last_4_provided);
                  return (
                    <Fieldset>
                      <div>
                        <FieldsetTitle>
                          <Label htmlFor={`${uid}-${taxIdConfig.idSuffix}`}>{taxIdConfig.label}</Label>
                        </FieldsetTitle>
                        <FieldsetDescription>
                          We are required to collect this information to satisfy regulatory obligations.
                        </FieldsetDescription>
                        {hasTaxIdOnFile && !isEditingTaxId ? (
                          <div className="flex flex-col gap-2">
                            <Input
                              id={`${uid}-${taxIdConfig.idSuffix}`}
                              type="text"
                              value={maskedTaxIdValue(taxIdConfig.placeholder)}
                              disabled
                              readOnly
                            />
                            <button
                              type="button"
                              className="cursor-pointer self-start text-sm underline all-unset"
                              onClick={() => setIsEditingTaxId(true)}
                              disabled={isFormDisabled}
                            >
                              Change
                            </button>
                          </div>
                        ) : (
                          <div className="flex flex-col gap-2">
                            <Input
                              id={`${uid}-${taxIdConfig.idSuffix}`}
                              type="text"
                              minLength={taxIdConfig.minLength}
                              maxLength={taxIdConfig.maxLength}
                              placeholder={taxIdConfig.placeholder}
                              required={!hasTaxIdOnFile}
                              disabled={isFormDisabled}
                              value={formState.id_number}
                              onChange={(event) => updateForm({ id_number: event.target.value })}
                            />
                            {isUs ? (
                              <button
                                type="button"
                                className="cursor-pointer self-start text-sm underline all-unset"
                                onClick={() => {
                                  setUseGovernmentIdForUs((prev) => !prev);
                                  updateForm({ id_number: "" });
                                }}
                                disabled={isFormDisabled}
                              >
                                {useGovernmentIdForUs
                                  ? "Use last 4 digits of Social Security number instead"
                                  : "Provide a government-issued ID number instead"}
                              </button>
                            ) : null}
                          </div>
                        )}
                      </div>
                    </Fieldset>
                  );
                })()}
              </>
            )}

            <div
              style={{
                display: "grid",
                gap: "var(--spacer-5)",
                gridAutoFlow: "column",
                gridAutoColumns: "1fr",
              }}
            >
              <Fieldset>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-title`}>Job title</Label>
                </FieldsetTitle>
                <Input
                  id={`${uid}-title`}
                  type="text"
                  disabled={isFormDisabled}
                  value={formState.title}
                  onChange={(event) => updateForm({ title: event.target.value })}
                />
              </Fieldset>
              <Fieldset>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-percent`}>Ownership %</Label>
                </FieldsetTitle>
                <Input
                  id={`${uid}-percent`}
                  type="number"
                  min={0}
                  max={100}
                  step="0.01"
                  required={formState.owner}
                  disabled={isFormDisabled}
                  value={formState.percent_ownership}
                  onChange={(event) => {
                    const value = event.target.value;
                    const hasOwnership = value !== "" && Number(value) > 0;
                    updateForm({ percent_ownership: value, owner: hasOwnership ? true : formState.owner });
                  }}
                />
              </Fieldset>
            </div>

            <Fieldset>
              <FieldsetTitle>
                <Label>Relationship</Label>
              </FieldsetTitle>
              <div
                style={{
                  display: "grid",
                  gap: "var(--spacer-5)",
                  gridAutoFlow: "column",
                  gridAutoColumns: "1fr",
                }}
              >
                <Label className="flex items-center gap-2">
                  <Checkbox
                    checked={formState.director}
                    disabled={isFormDisabled}
                    onChange={(event) => updateForm({ director: event.target.checked })}
                  />
                  Director
                </Label>
                <Label className="flex items-center gap-2">
                  <Checkbox
                    checked={formState.owner}
                    disabled={isFormDisabled}
                    onChange={(event) =>
                      updateForm({
                        owner: event.target.checked,
                        percent_ownership: event.target.checked ? formState.percent_ownership : "0",
                      })
                    }
                  />
                  Owner
                </Label>
                <Label className="flex items-center gap-2">
                  <Checkbox
                    checked={formState.executive}
                    disabled={isFormDisabled}
                    onChange={(event) => updateForm({ executive: event.target.checked })}
                  />
                  Executive
                </Label>
              </div>
            </Fieldset>

            <div className="flex flex-wrap gap-3">
              <Button color="primary" type="submit" disabled={isSaving || isFormDisabled}>
                {isSaving ? "Saving…" : editState.mode === "edit" ? "Save changes" : "Add owner"}
              </Button>
              <Button type="button" onClick={closeSheet} disabled={isSaving}>
                Cancel
              </Button>
            </div>
          </form>
        </Sheet>
      ) : null}

      {pendingDeletion ? (
        <Modal
          open
          onClose={() => (isDeleting ? null : setPendingDeletion(null))}
          title="Remove beneficial owner"
          footer={
            <>
              <Button onClick={() => setPendingDeletion(null)} disabled={isDeleting}>
                Cancel
              </Button>
              <Button color="danger" onClick={() => void handleConfirmDelete()} disabled={isDeleting}>
                {isDeleting ? "Removing…" : "Remove"}
              </Button>
            </>
          }
        >
          <p>
            Remove <strong>{fullName(pendingDeletion)}</strong> from this account? Stripe will be updated immediately.
          </p>
        </Modal>
      ) : null}
    </section>
  );
};

export default BeneficialOwnersSection;
