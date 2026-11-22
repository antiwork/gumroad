import { Plus, Trash } from "@boxicons/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";
import { uploadErrorMessage, uploadFileWithRetry } from "$app/utils/directUpload";

import { Button, buttonVariants } from "$app/components/Button";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { showAlert } from "$app/components/server-components/Alert";
import { Fieldset, FieldsetDescription } from "$app/components/ui/Fieldset";
import { Label } from "$app/components/ui/Label";
import { Placeholder } from "$app/components/ui/Placeholder";

const ALLOWED_EXTENSIONS = ["png", "jpg", "jpeg"];

// The recommended 1.91:1 shape, the generated subscribe card's. The upload is
// served uncropped and each preview app crops it its own way, some to a square,
// so this preview is a guide, not the exact result.
const PREVIEW_ASPECT_CLASS = "aspect-[1024/536]";

// Uploads straight to storage and reports the signed blob id the server
// attaches, like the profile picture input: the file never passes through the
// dashboard.
export const ShareImageInput = ({
  imageUrl,
  disabled = false,
  onChange,
  onUploadingChange,
}: {
  imageUrl: string | null;
  disabled?: boolean;
  onChange: (image: { signedId: string; url: string } | null) => void;
  onUploadingChange?: ((uploading: boolean) => void) | undefined;
}) => {
  const [uploading, setUploading] = React.useState(false);
  const id = React.useId();
  const updateUploading = (value: boolean) => {
    setUploading(value);
    onUploadingChange?.(value);
  };

  const handleFile = async (file: File) => {
    const extension = file.name.split(".").pop()?.toLowerCase() ?? "";
    if (!ALLOWED_EXTENSIONS.includes(extension)) {
      showAlert("Please choose a JPG or PNG image.", "error");
      return;
    }

    updateUploading(true);
    try {
      const blob = await uploadFileWithRetry(file, "/rails/active_storage/direct_uploads");
      onChange({ signedId: blob.signed_id, url: Routes.s3_utility_cdn_url_for_blob_path({ key: blob.key }) });
    } catch (error) {
      showAlert(uploadErrorMessage(error), "error");
    } finally {
      updateUploading(false);
    }
  };

  const accept = ALLOWED_EXTENSIONS.map((extension) => `.${extension}`).join(",");

  return (
    <Fieldset>
      <Label htmlFor={!uploading && imageUrl == null ? id : undefined}>Share image</Label>
      {uploading ? (
        <Placeholder className={classNames(PREVIEW_ASPECT_CLASS, "items-center")}>
          <LoadingSpinner className="size-8" aria-label="Uploading share image" />
        </Placeholder>
      ) : imageUrl == null ? (
        <Placeholder className={classNames(PREVIEW_ASPECT_CLASS, "items-center")}>
          <label className={classNames(buttonVariants({ size: "default", color: "primary" }), "relative")}>
            <input
              id={id}
              type="file"
              className="sr-only"
              accept={accept}
              disabled={disabled}
              onChange={(event) => {
                const file = event.target.files?.[0];
                event.target.value = "";
                if (file) void handleFile(file);
              }}
            />
            <Plus pack="filled" className="size-5" />
            Upload
          </label>
        </Placeholder>
      ) : (
        <figure className="relative">
          <img
            alt="Share image"
            src={imageUrl}
            className={classNames(
              PREVIEW_ASPECT_CLASS,
              "w-full rounded-sm border border-border bg-background object-cover",
            )}
          />
          <Button
            color="primary"
            size="icon"
            className="absolute top-2 right-2"
            aria-label="Remove share image"
            disabled={disabled}
            onClick={() => onChange(null)}
          >
            <Trash className="size-5" />
          </Button>
        </figure>
      )}
      <FieldsetDescription>
        Shared links to your home page and other pages use this image. Product images stay unchanged. JPG or PNG, up to
        5 MB. Recommended size: 1024x536px (1.91:1). Apps that show link previews may crop it, some to a square, so keep
        important content in the center. Without a share image, shared links show a card made from your profile, or your
        profile picture.
      </FieldsetDescription>
    </Fieldset>
  );
};
