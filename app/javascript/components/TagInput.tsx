import * as React from "react";

import { Select, Option, CustomOption, Props as SelectProps } from "./Select";

type Props = {
  tagIds: string[];
  onChangeTagIds: (newTagIds: string[]) => void;
  tagList: Option[];
  name?: string; // maintain the selected value/s in hidden field/s with this name
  noTagsLeftLabel?: string; // a label to show when all available tags have been already used
  noMatchingTagsLabel?: (query: string) => string; // a label to show when no available tags match the query
  inputId?: string;
  onKeyDown?: React.KeyboardEventHandler;
  placeholder?: string;
  inputValue?: string;
  onInputChange?: (newValue: string) => void;
  customOption?: CustomOption;
  maxTags?: number;
} & SelectProps<true>;

export const TagInput = ({
  tagIds,
  onChangeTagIds,
  tagList,
  noTagsLeftLabel,
  noMatchingTagsLabel,
  placeholder,
  maxTags,
  ...props
}: Props) => {
  const selectedTags = tagIds.map((tagId) => {
    const tag = tagList.find((tag) => tag.id === tagId);
    return tag || { id: tagId, label: tagId };
  });

  const getNoOptionMessage = (value: string) => {
    if (noTagsLeftLabel || noMatchingTagsLabel) {
      if (value === "") {
        return noTagsLeftLabel || "No additional items are available for selection.";
      }
      return noMatchingTagsLabel ? noMatchingTagsLabel(value) : `No items match "${value}".`;
    }
    return null;
  };

  return (
    <Select
      {...props}
      isClearable={false}
      isMulti
      value={selectedTags}
      onChange={(newValue) => onChangeTagIds(newValue.map((tag) => tag.id))}
      options={tagList}
      noOptionsMessage={({ inputValue }) => getNoOptionMessage(inputValue)}
      placeholder={placeholder}
      allowMenuOpen={() => !maxTags || selectedTags.length < maxTags}
    />
  );
};
