import { DirectUpload, DirectUploadDelegate, Blob } from "@rails/activestorage";
import { Node as ProseMirrorNode } from "@tiptap/pm/model";
import { EditorView } from "@tiptap/pm/view";
import { Editor, EditorContent } from "@tiptap/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { assertDefined } from "$app/utils/assert";
import FileUtils, { ALLOWED_EXTENSIONS } from "$app/utils/file";
import { assertResponseError, request } from "$app/utils/request";

import { PublicFileWithStatus } from "$app/components/ProductEdit/state";
import {
  getInsertAtFromSelection,
  ImageUploadSettingsContext,
  RichTextEditorToolbar,
  useRichTextEditor,
} from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import { MoveNode } from "$app/components/TiptapExtensions/MoveNode";
import { PublicFileEmbed } from "$app/components/TiptapExtensions/PublicFileEmbed";
import { useRunOnce } from "$app/components/useRunOnce";

const MAX_ALLOWED_PUBLIC_FILE_SIZE_IN_BYTES = 5 * 1024 * 1024; // 5MB
const MAX_ALLOWED_PUBLIC_FILES_COUNT = 5;

export const useImageUpload = () => {
  const [imagesUploading, setImagesUploading] = React.useState<Set<File>>(new Set());

  return { isUploading: imagesUploading.size > 0, setImagesUploading };
};

export const PublicFilesSettingsContext = React.createContext<{
  onUpload?: ({
    file,
    onSuccess,
    onError,
  }: {
    file: File;
    onSuccess?: (id: string) => void;
    onError?: (error: Error | null) => void;
  }) => void;
  cancelUpload?: (id: string) => void;
  updateFile?: (id: string, file: Partial<PublicFileWithStatus>) => void;
  files: PublicFileWithStatus[];
  audioPreviewsEnabled: boolean;
} | null>(null);

export const usePublicFilesSettings = () => {
  const context = React.useContext(PublicFilesSettingsContext);
  if (!context) throw new Error("usePublicFilesSettings must be used within a PublicFilesSettingsContext");
  return context;
};

const forEachPublicFile = (view: EditorView, id: string, cb: (descendant: ProseMirrorNode, nodePos: number) => void) =>
  view.state.doc.descendants((descendant, nodePos) => {
    if (descendant.type.name === PublicFileEmbed.name && descendant.attrs.id === id) cb(descendant, nodePos);
  });

const setPublicFileIdInView = (view: EditorView, id: string, newId: string) =>
  forEachPublicFile(view, id, (_, nodePos) => {
    view.dispatch(view.state.tr.setNodeMarkup(nodePos, undefined, { id: newId }));
  });

const deletePublicFileInView = (view: EditorView, id: string) =>
  forEachPublicFile(view, id, (descendant, nodePos) => {
    view.dispatch(view.state.tr.deleteRange(nodePos, nodePos + descendant.nodeSize));
  });

class Uploader implements DirectUploadDelegate {
  upload: DirectUpload;
  onProgress: (progress: number) => void;
  onSuccess: (blob: Blob) => void;
  onError: (error: Error | null) => void;
  cancel: () => void;
  xhr: XMLHttpRequest | null;

  constructor({
    file,
    url,
    onProgress,
    onSuccess,
    onError,
  }: {
    file: File;
    url: string;
    onProgress: (progress: number) => void;
    onSuccess: (blob: Blob) => void;
    onError: (error: Error | null) => void;
  }) {
    this.upload = new DirectUpload(file, url, this);
    this.onProgress = onProgress;
    this.onSuccess = onSuccess;
    this.onError = onError;
    this.xhr = null;

    this.cancel = () => {
      if (this.xhr) {
        this.xhr.abort();
        this.xhr = null;
      }
    };
  }

  uploadFile() {
    this.upload.create((error, blob) => {
      if (error) {
        this.onError(error);
      } else {
        this.onSuccess(blob);
      }
    });
  }

  directUploadWillStoreFileWithXHR(xhr: XMLHttpRequest): void {
    if (!this.xhr) {
      this.xhr = xhr;
    }

    xhr.upload.addEventListener("progress", (event) => {
      const progress = event.loaded / event.total;
      this.onProgress(progress);
    });
  }
}

export const DescriptionEditor = ({
  id,
  initialDescription,
  onChange,
  publicFiles,
  updatePublicFiles,
  setImagesUploading,
  audioPreviewsEnabled,
}: {
  id: string;
  initialDescription: string;
  onChange: (description: string) => void;
  publicFiles: PublicFileWithStatus[];
  updatePublicFiles: (updater: (prev: PublicFileWithStatus[]) => void) => void;
  setImagesUploading: React.Dispatch<React.SetStateAction<Set<File>>>;
  audioPreviewsEnabled: boolean;
}) => {
  const uid = React.useId();
  const [isMounted, setIsMounted] = React.useState(false);
  useRunOnce(() => setIsMounted(true));
  const editor = useRichTextEditor({
    id: uid,
    className: "textarea",
    ariaLabel: "Description",
    placeholder: "Describe your product...",
    initialValue: isMounted ? initialDescription : null,
    onChange,
    onInputNonImageFiles: (files: File[]) => {
      const file = files[0];
      if (!file) return;
      publicFilesSettings.onUpload({ file });
    },
    extensions: [PublicFileEmbed, MoveNode],
  });
  const [activeUploaders, setActiveUploaders] = React.useState<Map<string, Uploader>>(new Map());
  const deleteActiveUploader = (id: string) =>
    setActiveUploaders((prev) => {
      const newMap = new Map(prev);
      newMap.delete(id);
      return newMap;
    });
  const fileUploadCleanup = (editor: Editor, id: string) => {
    deletePublicFileInView(editor.view, id);
    deleteActiveUploader(id);
    updatePublicFiles((prev) => {
      const index = prev.findIndex((file) => file.id === id);
      if (index !== -1) {
        prev.splice(index, 1);
      }
    });
  };
  const publicFilesSettings = React.useMemo(
    () => ({
      onUpload: ({
        file,
        onSuccess,
        onError,
      }: {
        file: File;
        onSuccess?: (id: string) => void;
        onError?: (error: Error | null) => void;
      }) => {
        if (!editor) return;
        if (!audioPreviewsEnabled) return;

        if (!FileUtils.isAudioExtension(FileUtils.getFileExtension(file.name).toUpperCase())) {
          showAlert("Only audio files are allowed", "error");
          return;
        }

        const publicFileEmbeds = [];
        editor.view.state.doc.descendants((descendant) => {
          if (descendant.type.name === PublicFileEmbed.name) publicFileEmbeds.push(descendant);
        });
        if (publicFileEmbeds.length >= MAX_ALLOWED_PUBLIC_FILES_COUNT) {
          showAlert(
            `You can only upload up to ${MAX_ALLOWED_PUBLIC_FILES_COUNT} audio previews in the description`,
            "error",
          );
          return;
        }
        const insertAt = getInsertAtFromSelection(editor.state.selection);
        const publicFileSchema = assertDefined(
          editor.state.schema.nodes.publicFileEmbed,
          "publicFileEmbed node type missing",
        );
        if (file.size > MAX_ALLOWED_PUBLIC_FILE_SIZE_IN_BYTES) {
          showAlert(
            `File is too large (max allowed size is ${FileUtils.getReadableFileSize(
              MAX_ALLOWED_PUBLIC_FILE_SIZE_IN_BYTES,
            )})`,
            "error",
          );
          return;
        }

        const src = URL.createObjectURL(file);
        updatePublicFiles((prev) => {
          prev.push({
            id: src,
            name: FileUtils.getFileNameWithoutExtension(file.name),
            extension: FileUtils.getFileExtension(file.name).toUpperCase(),
            file_size: file.size,
            url: src,
            status: {
              type: "unsaved",
              uploadStatus: { type: "uploading", progress: { percent: 0, bitrate: 0 } },
              url: src,
            },
          });
        });
        const node = publicFileSchema.create({ id: src });
        editor.view.dispatch(editor.state.tr.insert(insertAt, node));
        const uploader = new Uploader({
          file,
          url: Routes.rails_direct_uploads_path(),
          onProgress: (progress) => {
            updatePublicFiles((prev) => {
              const file = prev.find((file) => file.id === src);
              if (file?.status?.type === "unsaved" && file.status.uploadStatus.type === "uploading") {
                file.status.uploadStatus.progress.percent = progress;
              }
            });
          },
          onSuccess: (blob) => {
            request({
              method: "POST",
              url: Routes.internal_product_public_files_path({ product_id: id, signed_blob_id: blob.signed_id }),
              accept: "json",
            })
              .then((response) => response.json())
              .then((data) => {
                const fileId = cast<{ id: string }>(data).id;
                updatePublicFiles((prev) => {
                  const file = prev.find((file) => file.id === src);
                  if (file) {
                    file.id = fileId;
                    file.status = { type: "saved" };
                  }
                });
                setPublicFileIdInView(editor.view, src, fileId);
                onSuccess?.(fileId);
                deleteActiveUploader(src);
              })
              .catch((error: unknown) => {
                fileUploadCleanup(editor, src);
                onError?.(error instanceof Error ? error : null);
                showAlert("Failed to upload the file. Please try again.", "error");
              });
          },
          onError: (error: Error | null) => {
            fileUploadCleanup(editor, src);
            onError?.(error);
            showAlert("Failed to upload the file. Please try again.", "error");
          },
        });
        setActiveUploaders((prev) => prev.set(src, uploader));
        uploader.uploadFile();
      },
      cancelUpload: (id: string) => {
        const uploader = activeUploaders.get(id);
        if (uploader) {
          uploader.cancel();
          if (editor) fileUploadCleanup(editor, id);
        }
      },
      files: publicFiles,
      updateFile: (id: string, fileData: Partial<PublicFileWithStatus>) => {
        updatePublicFiles((prev) => {
          const file = prev.find((file) => file.id === id);
          if (file) Object.assign(file, fileData);
        });
      },
      audioPreviewsEnabled,
    }),
    [publicFiles, editor, updatePublicFiles, deleteActiveUploader, fileUploadCleanup],
  );

  const imageSettings = React.useMemo(
    () => ({
      onUpload: (file: File) => {
        setImagesUploading((prev) => new Set(prev).add(file));
        return new Promise<string>((resolve, reject) => {
          const upload = new DirectUpload(file, Routes.rails_direct_uploads_path());
          upload.create((error, blob) => {
            setImagesUploading((prev) => {
              const updated = new Set(prev);
              updated.delete(file);
              return updated;
            });

            if (error) reject(error);
            else
              request({
                method: "GET",
                accept: "json",
                url: Routes.s3_utility_cdn_url_for_blob_path({ key: blob.key }),
              })
                .then((response) => response.json())
                .then((data) => resolve(cast<{ url: string }>(data).url))
                .catch((e: unknown) => {
                  assertResponseError(e);
                  reject(e);
                });
          });
        });
      },
      allowedExtensions: ALLOWED_EXTENSIONS,
    }),
    [],
  );

  if (!isMounted) return null;

  return (
    <fieldset>
      <label htmlFor={uid}>Description</label>
      <PublicFilesSettingsContext.Provider value={publicFilesSettings}>
        <ImageUploadSettingsContext.Provider value={imageSettings}>
          <div className="rich-text-editor" data-gumroad-ignore>
            {editor ? <RichTextEditorToolbar editor={editor} productId={id} /> : null}
            <EditorContent className="rich-text" editor={editor} />
          </div>
        </ImageUploadSettingsContext.Provider>
      </PublicFilesSettingsContext.Provider>
    </fieldset>
  );
};
