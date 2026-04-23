import { Search as SearchIcon } from "@boxicons/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { Popover, PopoverAnchor, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";

type SearchProps = {
  onSearch: (query: string) => void;
  value: string;
  placeholder?: string;
};

export const Search = ({ onSearch, value, placeholder = "Search" }: SearchProps) => {
  const [searchQuery, setSearchQuery] = React.useState(value);

  React.useEffect(() => {
    setSearchQuery(value);
  }, [value]);

  return (
    <Popover>
      <PopoverAnchor>
        <PopoverTrigger aria-label="Toggle Search" asChild>
          <Button size="icon">
            <SearchIcon className="size-5" />
          </Button>
        </PopoverTrigger>
      </PopoverAnchor>
      <PopoverContent sideOffset={4}>
        <InputGroup>
          <SearchIcon className="size-5 text-muted" />
          <Input
            value={searchQuery}
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
