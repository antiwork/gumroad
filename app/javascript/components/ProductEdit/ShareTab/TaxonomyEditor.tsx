import * as React from "react";

import { Taxonomy } from "$app/utils/discover";

import { buildCategoryOptions } from "$app/components/ProductEdit/ShareTab/taxonomyOptions";
import { Select } from "$app/components/Select";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Label } from "$app/components/ui/Label";

export const TaxonomyEditor = ({
  taxonomyId,
  onChange,
  taxonomies,
}: {
  taxonomyId: string | null;
  onChange: (taxonomyId: string | null) => void;
  taxonomies: Taxonomy[];
}) => {
  const uid = React.useId();
  const options = React.useMemo(() => buildCategoryOptions(taxonomies), [taxonomies]);

  return (
    <Fieldset>
      <FieldsetTitle>
        <Label htmlFor={uid}>Category</Label>
      </FieldsetTitle>
      <Select
        inputId={uid}
        placeholder="Begin typing to select a category"
        options={options}
        onChange={(taxonomy) => onChange(taxonomy?.id ?? null)}
        isMulti={false}
        isClearable
        value={options.find(({ id }) => id === taxonomyId) ?? null}
      />
      <FieldsetDescription>Select a category to show your product on Gumroad Discover.</FieldsetDescription>
    </Fieldset>
  );
};
