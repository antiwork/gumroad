import * as React from "react";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover, PopoverAnchor, PopoverContent, PopoverTrigger } from "$app/components/Popover";

type SearchProps = {
  onSearch: (query: string) => void;
  value: string;
  placeholder?: string;
};

export const Search = ({ onSearch, value: initialValue, placeholder = "Search" }: SearchProps) => {
  const searchInputRef = React.useRef<HTMLInputElement>(null);
  const [searchQuery, setSearchQuery] = React.useState(initialValue);
  const [open, setOpen] = React.useState(false);

  React.useEffect(() => {
    if (open) searchInputRef.current?.focus();
  }, [open]);

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverAnchor>
        <PopoverTrigger aria-label="Toggle Search" asChild>
          <Button>
            <Icon name="solid-search" />
          </Button>
        </PopoverTrigger>
      </PopoverAnchor>
      <PopoverContent sideOffset={4}>
        <div className="input input-wrapper">
          <Icon name="solid-search" />
          <input
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
        </div>
      </PopoverContent>
    </Popover>
  );
};
