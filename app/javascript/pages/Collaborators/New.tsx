import { usePage } from "@inertiajs/react";
import * as React from "react";

import { NewPageProps } from "$app/data/collaborators";
import { cast } from "$app/utils/cast";

import CollaboratorForm from "$app/components/Collaborators/Form";

export default function NewCollaboratorPage() {
  const { form_data, page_metadata, collaborators_disabled_reason } = cast<NewPageProps>(usePage().props);
  return (
    <CollaboratorForm
      form_data={form_data}
      page_metadata={page_metadata}
      collaborators_disabled_reason={collaborators_disabled_reason}
    />
  );
}
