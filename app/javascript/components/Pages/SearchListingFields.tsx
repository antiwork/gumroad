import * as React from "react";

import { ShareImageInput } from "$app/components/Pages/ShareImageInput";
import { Fieldset, FieldsetDescription } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { Textarea } from "$app/components/ui/Textarea";

export type SeoMaxLengths = { title: number; description: number };
export type ShareImageSelection = { signedId: string; url: string };

// The search title, description and share image for a storefront page or the
// home page. The listing preview shows what a blank field falls back to, so the
// seller sees the result of leaving a field empty without reading the hints.
export const SearchListingFields = ({
  url,
  title,
  description,
  defaultTitle,
  defaultDescription,
  maxLengths,
  disabled,
  onTitleChange,
  onDescriptionChange,
  shareImageUrl,
  onShareImageChange,
  onShareImageUploadingChange,
}: {
  url: string;
  title: string;
  description: string;
  defaultTitle: string;
  defaultDescription: string | null;
  maxLengths: SeoMaxLengths;
  disabled: boolean;
  onTitleChange: (title: string) => void;
  onDescriptionChange: (description: string) => void;
  // Only the profile has a share image; a slugged page passes no callback and
  // the field is not rendered.
  shareImageUrl?: string | null;
  onShareImageChange?: (image: ShareImageSelection | null) => void;
  onShareImageUploadingChange?: (uploading: boolean) => void;
}) => {
  const uid = React.useId();
  const listingTitle = title.trim() || defaultTitle;
  const listingDescription = description.trim() || defaultDescription;

  return (
    <section id="search-listing" className="grid gap-4" aria-labelledby={`${uid}-heading`}>
      <header className="grid gap-1">
        <h3 id={`${uid}-heading`}>Search and sharing</h3>
        <p className="text-sm text-muted">Set what search engines and shared links show for this page.</p>
      </header>
      <div className="grid gap-1 rounded border border-border bg-background p-4" aria-label="Search listing preview">
        <span className="truncate text-sm text-muted">{url.replace(/^https?:\/\//u, "")}</span>
        <span className="text-lg leading-snug">{listingTitle}</span>
        {listingDescription ? (
          <span className="line-clamp-2 text-sm">{listingDescription}</span>
        ) : (
          <span className="text-sm text-muted">Search engines choose text from the page.</span>
        )}
      </div>
      <Fieldset>
        <div className="flex items-baseline justify-between gap-2">
          <Label htmlFor={`${uid}-title`}>Title in search results</Label>
          <small className="text-muted tabular-nums">
            {title.length}/{maxLengths.title}
          </small>
        </div>
        <Input
          id={`${uid}-title`}
          type="text"
          value={title}
          placeholder={defaultTitle}
          maxLength={maxLengths.title}
          disabled={disabled}
          onChange={(e) => onTitleChange(e.target.value)}
        />
        <FieldsetDescription>
          Also shows in browser tabs and shared links. Leave blank to use the default.
        </FieldsetDescription>
      </Fieldset>
      <Fieldset>
        <div className="flex items-baseline justify-between gap-2">
          <Label htmlFor={`${uid}-description`}>Description in search results</Label>
          <small className="text-muted tabular-nums">
            {description.length}/{maxLengths.description}
          </small>
        </div>
        <Textarea
          id={`${uid}-description`}
          rows={3}
          value={description}
          placeholder={defaultDescription ?? ""}
          maxLength={maxLengths.description}
          disabled={disabled}
          onChange={(e) => onDescriptionChange(e.target.value)}
        />
        <FieldsetDescription>Also shows in shared links. Leave blank to use the default.</FieldsetDescription>
      </Fieldset>
      {onShareImageChange ? (
        <ShareImageInput
          imageUrl={shareImageUrl ?? null}
          disabled={disabled}
          onChange={onShareImageChange}
          onUploadingChange={onShareImageUploadingChange}
        />
      ) : null}
    </section>
  );
};
