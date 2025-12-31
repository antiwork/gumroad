import { DirectUpload } from "@rails/activestorage";
import * as React from "react";

import { ImageUploader } from "$app/components/ImageUploader";
import { showAlert } from "$app/components/server-components/Alert";

const ALLOWED_EXTENSIONS = ["jpeg", "jpg", "png"];

// This component only allows you to replace (not remove) the profile picture.
export const LogoInput = ({
  onChange,
  logoUrl,
  disabled,
}: {
  logoUrl: string;
  disabled: boolean;
  onChange: (blob: { key: string; signedId: string } | null) => void;
}) => {
  const [changing, setChanging] = React.useState(false);
  const id = React.useId();

  return (
    <fieldset>
      <legend className="mb-2">
        <label htmlFor={id}>Logo</label>
      </legend>
      <ImageUploader
        id={id}
        helpText="Your logo will be visible next to your name in your Gumroad profile and product pages. Your image should be at least 200x200px and must be in JPG or PNG format."
        allowedExtensions={ALLOWED_EXTENSIONS}
        imageUrl={changing ? null : logoUrl}
        onRemove={() => {
          setChanging(true);
          onChange(null);
        }}
        onSelectFile={(file) =>
          new Promise((resolve, reject) => {
            const upload = new DirectUpload(file, "/rails/active_storage/direct_uploads");

            upload.create((error, blob) => {
              setChanging(false);
              if (error) {
                showAlert(error.message, "error");
                reject(error);
              } else {
                onChange({ key: blob.key, signedId: blob.signed_id });
                resolve();
              }
            });
          })
        }
        imageAlt="Current logo"
        disabled={disabled}
      />
    </fieldset>
  );
};
