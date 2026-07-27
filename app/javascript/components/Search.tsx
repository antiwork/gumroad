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

// Copying an email address from a mail client (notably "Copy" on an email link in iOS Mail) puts
// the whole link on the clipboard — "mailto:someone@example.com" — instead of the bare address.
// Pasted as-is, that never matches a stored purchase email, so the search silently returns nothing
// and it looks to the seller like we lost their customer. A leading "mailto:" is never something
// anyone means to search for, so drop it. Also handles the "mailto://" variant some apps produce
// and the "?subject=..." parameters a mailto link can carry.
const MAILTO_PREFIX = /^\s*mailto:(?:\/\/)?/iu;

export const normalizeSearchQuery = (raw: string): string => {
  if (!MAILTO_PREFIX.test(raw)) return raw;

  const withoutPrefix = raw.replace(MAILTO_PREFIX, "").split("?")[0] ?? "";
  // mailto links are URLs, so the address may be percent-encoded ("foo%40example.com"). Decoding
  // can throw on a malformed sequence (a bare "%" the seller typed), in which case we keep the
  // undecoded text rather than losing what they pasted.
  let decoded = withoutPrefix;
  try {
    decoded = decodeURIComponent(withoutPrefix);
  } catch {
    /* keep the raw text */
  }
  return decoded.trim();
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
              // Normalize the visible text too, not just what we send to the server, so the field
              // shows the seller exactly what is being searched for.
              const query = normalizeSearchQuery(e.target.value);
              setSearchQuery(query);
              onSearch(query);
            }}
          />
        </InputGroup>
      </PopoverContent>
    </Popover>
  );
};
