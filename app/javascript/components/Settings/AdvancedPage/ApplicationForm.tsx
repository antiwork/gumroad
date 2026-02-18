import { router } from "@inertiajs/react";
import { DirectUpload } from "@rails/activestorage";
import placeholderAppIcon from "images/gumroad_app.png";
import * as React from "react";
import { cast } from "ts-safe-cast";

import FileUtils from "$app/utils/file";
import { getImageDimensionsFromFile } from "$app/utils/image";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { WithTooltip } from "$app/components/WithTooltip";

export type Application = {
  id: string;
  name: string;
  redirect_uri: string;
  icon_url: string | null;
  uid: string;
  secret: string;
};

const ALLOWED_ICON_EXTENSIONS = ["jpeg", "jpg", "png"];

const ApplicationForm = ({ application }: { application?: Application }) => {
  const [name, setName] = React.useState<{ value: string; error?: boolean }>({ value: application?.name ?? "" });
  const [isSubmitting, setIsSubmitting] = React.useState(false);
  const [isGeneratingToken, setIsGeneratingToken] = React.useState(false);
  const [icon, setIcon] = React.useState<{ url: string; signedBlobId: string } | { url: string } | null>(
    application?.icon_url ? { url: application.icon_url } : null,
  );
  const [redirectUri, setRedirectUri] = React.useState<{ value: string; error?: boolean }>({
    value: application?.redirect_uri ?? "",
  });
  const [token, setToken] = React.useState<string | null>(null);
  const [isUploadingIcon, setIsUploadingIcon] = React.useState(false);
  const nameRef = React.useRef<null | HTMLInputElement>(null);
  const redirectUriRef = React.useRef<null | HTMLInputElement>(null);
  const iconInputRef = React.useRef<null | HTMLInputElement>(null);
  const uid = React.useId();

  const isFormValid = () => {
    let isValid = true;
    if (redirectUri.value.trim().length === 0) {
      isValid = false;
      setRedirectUri((prevRedirectUri) => ({ ...prevRedirectUri, error: true }));
      redirectUriRef.current?.focus();
    }
    if (name.value.trim().length === 0) {
      isValid = false;
      setName((prevName) => ({ ...prevName, error: true }));
      nameRef.current?.focus();
    }
    return isValid;
  };

  const handleSubmit = () => {
    if (!isFormValid()) return;

    setIsSubmitting(true);

    const data = {
      oauth_application: {
        name: name.value,
        redirect_uri: redirectUri.value,
      },
      signed_blob_id: icon && "signedBlobId" in icon ? icon.signedBlobId : null,
    };

    if (application) {
      router.put(Routes.oauth_application_path(application.id), data, {
        preserveScroll: true,
        onSuccess: () => {
          showAlert("Application updated.", "success");
          setIsSubmitting(false);
        },
        onError: (errors: Record<string, string | string[]>) => {
          const message = errors.base
            ? Array.isArray(errors.base)
              ? errors.base[0]
              : errors.base
            : "Sorry, something went wrong. Please try again.";
          if (message) showAlert(message, "error");
          setIsSubmitting(false);
        },
      });
    } else {
      router.post(Routes.oauth_applications_path(), data, {
        onSuccess: () => {
          showAlert("Application created.", "success");
          setIsSubmitting(false);
        },
        onError: (errors: Record<string, string | string[]>) => {
          const message = errors.base
            ? Array.isArray(errors.base)
              ? errors.base[0]
              : errors.base
            : "Sorry, something went wrong. Please try again.";
          if (message) showAlert(message, "error");
          setIsSubmitting(false);
        },
      });
    }
  };

  const handleIconChange = asyncVoid(async () => {
    const file = iconInputRef.current?.files?.[0];
    if (!file) return;
    const dimensions = await getImageDimensionsFromFile(file).catch(() => null);
    if (!dimensions || !FileUtils.isFileNameExtensionAllowed(file.name, ALLOWED_ICON_EXTENSIONS)) {
      showAlert("Invalid file type.", "error");
      return;
    }
    setIsUploadingIcon(true);

    const upload = new DirectUpload(file, Routes.rails_direct_uploads_path());
    upload.create((error, blob) => {
      if (error) {
        showAlert(error.message, "error");
      } else {
        setIcon({
          url: Routes.s3_utility_cdn_url_for_blob_path({ key: blob.key }),
          signedBlobId: blob.signed_id,
        });
      }
      setIsUploadingIcon(false);
      if (iconInputRef.current) iconInputRef.current.value = "";
    });
  });

  return (
    <>
      <input
        ref={iconInputRef}
        type="file"
        className="sr-only"
        accept={ALLOWED_ICON_EXTENSIONS.map((ext) => `.${ext}`).join(",")}
        tabIndex={-1}
        onChange={handleIconChange}
      />
      <Fieldset>
        <FieldsetTitle>
          <Label>Application icon</Label>
        </FieldsetTitle>
        <div style={{ display: "flex", gap: "var(--spacer-4)", alignItems: "flex-start" }}>
          <img className="application-icon" src={icon?.url || placeholderAppIcon} width={80} height={80} />
          <Button onClick={() => iconInputRef.current?.click()} disabled={isUploadingIcon || isSubmitting}>
            {isUploadingIcon ? "Uploading..." : "Upload icon"}
          </Button>
        </div>
      </Fieldset>
      <Fieldset state={name.error ? "danger" : undefined}>
        <FieldsetTitle>
          <Label htmlFor={`${uid}-name`}>Application name</Label>
        </FieldsetTitle>
        <Input
          id={`${uid}-name`}
          ref={nameRef}
          placeholder="Name"
          type="text"
          value={name.value}
          onChange={(e) => setName({ value: e.target.value })}
        />
      </Fieldset>
      <Fieldset state={redirectUri.error ? "danger" : undefined}>
        <FieldsetTitle>
          <Label htmlFor={`${uid}-redirectUri`}>Redirect URI</Label>
        </FieldsetTitle>
        <Input
          id={`${uid}-redirectUri`}
          ref={redirectUriRef}
          placeholder="http://yourapp.com/callback"
          title="Redirect URI must have host and scheme and no fragment."
          type="url"
          value={redirectUri.value}
          onChange={(e) => setRedirectUri({ value: e.target.value })}
        />
      </Fieldset>

      {application ? (
        <>
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-uid`}>Application ID</Label>
            </FieldsetTitle>
            <Input id={`${uid}-uid`} readOnly type="text" value={application.uid} />
          </Fieldset>
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-secret`}>Application Secret</Label>
            </FieldsetTitle>
            <Input id={`${uid}-secret`} readOnly type="text" value={application.secret} />
          </Fieldset>

          {token ? (
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-accessToken`}>
                  Access Token
                  <WithTooltip tip="This is a ready-to-use access token for our API.">
                    <span>(?)</span>
                  </WithTooltip>
                </Label>
              </FieldsetTitle>
              <Input id={`${uid}-accessToken`} readOnly type="text" value={token} />
            </Fieldset>
          ) : null}
          <div className="flex gap-2">
            <Button color="accent" onClick={handleSubmit} disabled={isSubmitting || isUploadingIcon}>
              <span>{isSubmitting ? "Updating..." : "Update application"}</span>
            </Button>

            {!token ? (
              <Button
                onClick={asyncVoid(async () => {
                  setIsGeneratingToken(true);
                  try {
                    const response = await request({
                      url: Routes.settings_application_access_tokens_path(application.id),
                      method: "POST",
                      accept: "json",
                    });
                    const responseData = cast<{ success: true; token: string } | { success: false; message: string }>(
                      await response.json(),
                    );
                    if (!responseData.success) throw new ResponseError(responseData.message);
                    setToken(responseData.token);
                  } catch (e) {
                    assertResponseError(e);
                    showAlert(e.message, "error");
                  }
                  setIsGeneratingToken(false);
                })}
                disabled={isGeneratingToken}
              >
                <span>{isGeneratingToken ? "Generating..." : "Generate access token"}</span>
              </Button>
            ) : null}
          </div>
        </>
      ) : (
        <div>
          <Button color="primary" onClick={handleSubmit} disabled={isSubmitting || isUploadingIcon}>
            <span>{isSubmitting ? "Creating..." : "Create application"}</span>
          </Button>
        </div>
      )}
    </>
  );
};

export default ApplicationForm;
