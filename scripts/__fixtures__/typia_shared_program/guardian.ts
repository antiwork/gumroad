import typia from "typia";

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

export const save = async (response: { ok: boolean; json: () => Promise<unknown> }) => {
  if (!response.ok) {
    const body = typia.assert<{ error?: string }>(await response.json().catch(() => ({})));
    throw new Error(body.error ?? "Something went wrong.");
  }
  // A comment between the two checks, as in the real component.
  const { guardian } = typia.assert<{ guardian: Guardian }>(await response.json());
  return guardian.has_completed_info ? "saved" : "saved, but incomplete";
};
