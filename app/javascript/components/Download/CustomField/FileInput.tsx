import { DirectUpload } from "@rails/activestorage";
import * as React from "react";

import FileUtils from "$app/utils/file";
import { asyncVoid } from "$app/utils/promise";
import { request } from "$app/utils/request";

import { FileKindIcon } from "$app/components/FileRowContent";
import { Icon } from "$app/components/Icons";
import { showAlert } from "$app/components/server-components/Alert";
import { usePurchaseCustomFields, usePurchaseInfo } from "$app/components/server-components/DownloadPage/WithContent";
import Placeholder from "$app/components/ui/Placeholder";

const MAX_FILE_SIZE = 10 * 1024 * 1024;

export const FileInput = ({ customFieldId }: { customFieldId: string }) => {
  const purchaseInfo = usePurchaseInfo();
  const purchaseCustomFields = usePurchaseCustomFields();
  const [isUploading, setIsUploading] = React.useState(false);

  const [files, setFiles] = React.useState<{ name: string; size: number; extension: string }[]>(() => {
    const purchaseCustomField = purchaseCustomFields.find(
      (purchaseCustomField) => purchaseCustomField.custom_field_id === customFieldId,
    );
    return purchaseCustomField?.type === "fileUpload" ? purchaseCustomField.files : [];
  });

  const handleFileChange = asyncVoid(async (event: React.ChangeEvent<HTMLInputElement>) => {
    if (!event.target.files?.length) return;

    setIsUploading(true);

    try {
      const filesToUpload = Array.from(event.target.files);

      if (filesToUpload.some((file) => file.size > MAX_FILE_SIZE)) {
        return showAlert("Files must be smaller than 10 MB", "error");
      }

      const signedIds = await Promise.all(
        filesToUpload.map(
          (file) =>
            new Promise<string>((resolve, reject) => {
              new DirectUpload(file, Routes.rails_direct_uploads_path()).create((error, blob) => {
                if (error) reject(error);
                else resolve(blob.signed_id);
              });
            }),
        ),
      );

      await request({
        method: "POST",
        accept: "json",
        url: Routes.purchase_custom_fields_path(),
        data: {
          purchase_id: purchaseInfo.purchaseId,
          custom_field_id: customFieldId,
          file_signed_ids: signedIds,
        },
      });

      setFiles((prevFiles) => [
        ...prevFiles,
        ...filesToUpload.map((file) => ({
          name: FileUtils.getFileNameWithoutExtension(file.name),
          size: file.size,
          extension: FileUtils.getFileExtension(file.name).toUpperCase(),
        })),
      ]);

      showAlert("Files uploaded successfully!", "success");
    } catch {
      showAlert("Error uploading files. Please try again.", "error");
    } finally {
      setIsUploading(false);
    }
  });

  const fileUpload = (
    <label className="button primary">
      <input type="file" onChange={handleFileChange} disabled={isUploading} multiple />
      <Icon name="upload-fill" />
      Upload files
    </label>
  );

  return files.length ? (
    <div className="stack">
      <div>
        <div role="tree">
          {files.map((file, index) => (
            <div key={index} role="treeitem">
              <div className="content">
                <FileKindIcon extension={file.extension} />
                <div>
                  <h4>{file.name}</h4>
                  <ul className="inline">
                    <li>{file.extension}</li>
                    <li>{FileUtils.getFullFileSizeString(file.size)}</li>
                  </ul>
                </div>
              </div>
            </div>
          ))}
        </div>
      </div>
      <div style={{ justifyContent: "center" }}>{fileUpload}</div>
    </div>
  ) : (
    <Placeholder>
      {fileUpload}
      <div>Files must be smaller than 10 MB</div>
    </Placeholder>
  );
};
