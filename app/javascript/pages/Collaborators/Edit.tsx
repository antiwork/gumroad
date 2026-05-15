import { usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { EditPageProps } from "$app/data/collaborators";

import CollaboratorForm from "$app/components/Collaborators/Form";

export default function EditCollaboratorPage() {
  const { form_data, page_metadata, collaborators_disabled_reason } = typia.assert<EditPageProps>(usePage().props);
  return (
    <CollaboratorForm
      form_data={form_data}
      page_metadata={page_metadata}
      collaborators_disabled_reason={collaborators_disabled_reason}
    />
  );
}
