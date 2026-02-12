import * as React from "react";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover, PopoverAnchor, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";

type SearchProps = {
  onSearch: (query: string) => void;
  value: string;
  placeholder?: string;
};

export const Search = ({ onSearch, value: initialValue, placeholder = "Search" }: SearchProps) => {
  const searchInputRef = React.useRef<HTMLInputElement>(null);
  const [searchQuery, setSearchQuery] = React.useState(initialValue);

  return (
    <Popover>
      <PopoverAnchor>
        <PopoverTrigger aria-label="Toggle Search" asChild>
          <Button>
            <Icon name="solid-search" />
          </Button>
        </PopoverTrigger>
      </PopoverAnchor>
      <PopoverContent sideOffset={4} onOpenAutoFocus={() => searchInputRef.current?.focus()}>
        <InputGroup>
          <Icon name="solid-search" />
          <Input
            ref={searchInputRef}
            value={searchQuery}
            autoFocus
            type="text"
            placeholder={placeholder}
            onChange={(e) => {
              setSearchQuery(e.target.value);
              onSearch(e.target.value);
            }}
          />
        </InputGroup>
      </PopoverContent>
    </Popover>
  );
};
