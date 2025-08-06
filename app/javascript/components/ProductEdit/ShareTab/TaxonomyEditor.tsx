import * as React from "react";

import { Taxonomy } from "$app/utils/discover";

import { Select } from "$app/components/Select";

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
  const options = React.useMemo(() => {
    const taxonomyMap = new Map(taxonomies.map((item) => [item.key, item]));
    return taxonomies
      .filter((taxonomy) => taxonomy.label !== null)
      .map((taxonomy) => {
        let label = taxonomy.label as string;
        let current: Taxonomy | undefined = taxonomy;
        while ((current = taxonomyMap.get(current.parent_key ?? ""))) {
          if (current.label) {
            label = `${current.label} > ${label}`;
          }
        }
        return { id: taxonomy.key, label };
      });
  }, [taxonomies]);

  return (
    <fieldset>
      <legend>
        <label htmlFor={uid}>Category</label>
      </legend>
      <Select
        inputId={uid}
        placeholder="Begin typing to select a category"
        options={options}
        onChange={(taxonomy) => onChange(taxonomy?.id ?? null)}
        isMulti={false}
        isClearable
        value={options.find(({ id }) => id === taxonomyId) ?? null}
      />
      <small>Select a category to show your product on Gumroad Discover.</small>
    </fieldset>
  );
};
