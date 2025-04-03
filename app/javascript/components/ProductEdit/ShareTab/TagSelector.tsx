import * as React from "react";

import { Tag, getProductTags } from "$app/data/product_tags";
import { assertResponseError } from "$app/utils/request";

import { showAlert } from "$app/components/server-components/Alert";
import { TagInput } from "$app/components/TagInput";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useOnChange } from "$app/components/useOnChange";

const MAX_ALLOWED_TAGS = 5;
const MIN_TAG_LENGTH = 2;
const MAX_TAG_LENGTH = 20;
const clean = (tag: string) => tag.toLowerCase().replace(/^[#\s]+|,/gu, "");

export const TagSelector = ({ tags, onChange }: { tags: string[]; onChange: (tags: string[]) => void }) => {
  const uid = React.useId();

  const [query, setQuery] = React.useState("");
  const cleanedQuery = clean(query).trim();

  const [suggestions, setSuggestions] = React.useState<Tag[]>([]);
  const loadSuggestions = useDebouncedCallback(() => {
    if (!cleanedQuery) return setSuggestions([]);
    getProductTags({ text: cleanedQuery }).then(setSuggestions, (err: unknown) => {
      assertResponseError(err);
      showAlert(err.message, "error");
    });
  }, 300);
  useOnChange(loadSuggestions, [cleanedQuery]);

  const validatedTag = cleanedQuery.length >= MIN_TAG_LENGTH ? cleanedQuery : null;

  const handleKeyDown = (evt: React.KeyboardEvent) => {
    if (validatedTag && tags.length < MAX_ALLOWED_TAGS && evt.key === ",") {
      evt.preventDefault();
      onChange([...tags, validatedTag]);
      setQuery("");
    }
  };

  return (
    <fieldset>
      <legend>
        <label htmlFor={uid}>Tags</label>
      </legend>
      <TagInput
        inputId={uid}
        tagIds={tags}
        onChangeTagIds={(newTags) => {
          // Some existing products have more than the maximum number of tags
          if (newTags.length <= MAX_ALLOWED_TAGS || newTags.length < tags.length) onChange(newTags);
        }}
        tagList={[
          ...tags.map((tag) => ({ id: tag, label: tag })),
          ...suggestions.map((suggestion) => ({
            id: suggestion.name,
            label: `${suggestion.name} (${suggestion.uses})`,
          })),
          ...(validatedTag && !suggestions.some(({ name }) => name === validatedTag)
            ? [{ id: validatedTag, label: validatedTag }]
            : []),
        ]}
        onKeyDown={handleKeyDown}
        placeholder="Begin typing to add a tag..."
        inputValue={query}
        onInputChange={setQuery}
        maxLength={MAX_TAG_LENGTH}
        maxTags={MAX_ALLOWED_TAGS}
      />
    </fieldset>
  );
};
