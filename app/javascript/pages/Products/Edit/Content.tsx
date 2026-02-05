import { useForm, usePage } from "@inertiajs/react";
import { findChildren, generateJSON, Node as TiptapNode } from "@tiptap/core";
import { DOMSerializer } from "@tiptap/pm/model";
import { EditorContent } from "@tiptap/react";
import { parseISO } from "date-fns";
import { partition } from "lodash-es";
import * as React from "react";
import { ReactSortable } from "react-sortablejs";
import { cast } from "ts-safe-cast";

import { fetchDropboxFiles, ResponseDropboxFile, uploadDropboxFile } from "$app/data/dropbox_upload";
import { useDropbox } from "$app/hooks/useDropbox";
import { type Post } from "$app/types/workflow";
import { escapeRegExp } from "$app/utils";
import { assertDefined } from "$app/utils/assert";
import { type CurrencyCode } from "$app/utils/currency";
import { formatDate } from "$app/utils/date";
import FileUtils from "$app/utils/file";
import GuidGenerator from "$app/utils/guid_generator";
import { getMimeType } from "$app/utils/mimetypes";
import { assertResponseError, request, ResponseError } from "$app/utils/request";
import { generatePageIcon } from "$app/utils/rich_content_page";

import { Button } from "$app/components/Button";
import { InputtedDiscount } from "$app/components/CheckoutDashboard/DiscountInput";
import { ComboBox } from "$app/components/ComboBox";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { PageList, PageListLayout, PageListItem } from "$app/components/Download/PageListLayout";
import { EvaporateUploaderProvider, useEvaporateUploader } from "$app/components/EvaporateUploader";
import { FileKindIcon } from "$app/components/FileRowContent";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Modal } from "$app/components/Modal";
import { Popover, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { FileEmbed, FileEmbedConfig, getDownloadUrl } from "$app/components/ProductEdit/ContentTab/FileEmbed";
import { FileEmbedGroup } from "$app/components/ProductEdit/ContentTab/FileEmbedGroup";
import { Page, PageTab, titleWithFallback } from "$app/components/ProductEdit/ContentTab/PageTab";
import { Layout } from "$app/components/ProductEdit/Layout";
import { ProductPreview } from "$app/components/ProductEdit/ProductPreview";
import {
  type ExistingFileEntry,
  type FileEntry,
  type Variant,
  type Product as ProductType,
} from "$app/components/ProductEdit/state";
import { ReviewForm } from "$app/components/ReviewForm";
import {
  baseEditorOptions,
  getInsertAtFromSelection,
  PopoverMenuItem,
  RichTextEditorToolbar,
  useImageUploadSettings,
  useRichTextEditor,
  validateUrl,
} from "$app/components/RichTextEditor";
import type { ImageUploadSettings } from "$app/components/RichTextEditor";
import { S3UploadConfigProvider, useS3UploadConfig } from "$app/components/S3UploadConfig";
import { Separator } from "$app/components/Separator";
import { showAlert } from "$app/components/server-components/Alert";
import { EntityInfo } from "$app/components/server-components/DownloadPage/Layout";
import { TestimonialSelectModal } from "$app/components/TestimonialSelectModal";
import { FileUpload } from "$app/components/TiptapExtensions/FileUpload";
import { uploadImages } from "$app/components/TiptapExtensions/Image";
import { LicenseKey, LicenseProvider } from "$app/components/TiptapExtensions/LicenseKey";
import { LinkMenuItem } from "$app/components/TiptapExtensions/Link";
import { LongAnswer } from "$app/components/TiptapExtensions/LongAnswer";
import { EmbedMediaForm, insertMediaEmbed, ExternalMediaFileEmbed } from "$app/components/TiptapExtensions/MediaEmbed";
import { MoreLikeThis } from "$app/components/TiptapExtensions/MoreLikeThis";
import { MoveNode } from "$app/components/TiptapExtensions/MoveNode";
import { Posts, PostsProvider } from "$app/components/TiptapExtensions/Posts";
import { ShortAnswer } from "$app/components/TiptapExtensions/ShortAnswer";
import { UpsellCard } from "$app/components/TiptapExtensions/UpsellCard";
import { Card, CardContent } from "$app/components/ui/Card";
import { Row, RowContent, Rows } from "$app/components/ui/Rows";
import { Tabs, Tab } from "$app/components/ui/Tabs";
import { UpsellSelectModal, Product, ProductOption } from "$app/components/UpsellSelectModal";
import { useConfigureEvaporate } from "$app/components/useConfigureEvaporate";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";
import { useRefToLatest } from "$app/components/useRefToLatest";
import { WithTooltip } from "$app/components/WithTooltip";

declare global {
  interface Window {
    ___dropbox_files_picked: DropboxFile[] | null;
  }
}

export const extensions = (productId: string, extraExtensions: TiptapNode[] = []) => [
  ...extraExtensions,
  ...[
    FileEmbed,
    FileEmbedGroup,
    ExternalMediaFileEmbed,
    Posts,
    LicenseKey,
    ShortAnswer,
    LongAnswer,
    FileUpload,
    MoveNode,
    UpsellCard,
    MoreLikeThis.configure({ productId }),
  ].filter((ext) => !extraExtensions.some((existing) => existing.name === ext.name)),
];

type ContentPageProps = {
  product: ProductType;
  id: string;
  unique_permalink: string;
  existing_files: ExistingFileEntry[];
  aws_access_key_id: string;
  s3_url: string;
  user_id: string;
  ratings: {
    count: number;
    average: number;
    percentages: [number, number, number, number, number];
  };
  seller_refund_policy_enabled: boolean;
  seller_refund_policy: {
    title: string;
    fine_print: string;
  };
  currency_type: CurrencyCode;
};

type SellerType = {
  id: string;
  name: string;
  profile_url: string;
  avatar_url: string | null;
};

type UpdateProductKey = "files" | "variants" | "rich_content" | "has_same_rich_content_for_all_variants";
type UpdateProductKV = <K extends UpdateProductKey>(key: K, value: ProductType[K]) => void;

const ContentTabContent = ({
  selectedVariantId,
  product,
  updateProduct,
  existingFiles,
  save,
  filesById,
  seller,
  imageSettings,
  id,
  unique_permalink,
}: {
  selectedVariantId: string | null;
  product: ProductType;
  updateProduct: UpdateProductKV;
  existingFiles: ExistingFileEntry[];
  save: () => void;
  filesById: Map<string, FileEntry>;
  seller: SellerType;
  imageSettings: ImageUploadSettings | null;
  id: string;
  unique_permalink: string;
}) => {
  const uid = React.useId();
  const isDesktop = useIsAboveBreakpoint("lg");

  const selectedVariant = product.has_same_rich_content_for_all_variants
    ? null
    : product.variants.find((variant) => variant.id === selectedVariantId);

  const pages: (Page & { chosen?: boolean })[] = selectedVariant ? selectedVariant.rich_content : product.rich_content;
  const pagesRef = useRefToLatest(pages);

  const updatePages = (pages: Page[]) => {
    if (selectedVariant) {
      const nt = product.native_type;
      if (nt === "membership") {
        const newVariants = product.variants.map((v) =>
          v.id === selectedVariantId ? { ...v, rich_content: pages } : v,
        );
        updateProduct("variants", newVariants);
      } else if (nt === "call") {
        const newVariants = product.variants.map((v) =>
          v.id === selectedVariantId ? { ...v, rich_content: pages } : v,
        );
        updateProduct("variants", newVariants);
      } else {
        const newVariants = product.variants.map((v) =>
          v.id === selectedVariantId ? { ...v, rich_content: pages } : v,
        );
        updateProduct("variants", newVariants);
      }
    } else {
      updateProduct("has_same_rich_content_for_all_variants", true);
      updateProduct("rich_content", pages);
    }
  };

  const addPage = (description?: object) => {
    const page = {
      id: GuidGenerator.generate(),
      description: description ?? { type: "doc", content: [{ type: "paragraph" }] },
      title: null,
      updated_at: new Date().toISOString(),
    };
    updatePages([...pages, page]);
    setSelectedPageId(page.id);
    return page;
  };

  const [selectedPageId, setSelectedPageId] = React.useState(pages[0]?.id);
  const selectedPage = pages.find((page) => page.id === selectedPageId);
  if ((selectedPageId || pages.length) && !selectedPage) setSelectedPageId(pages[0]?.id);
  const [renamingPageId, setRenamingPageId] = React.useState<string | null>(null);
  const [confirmingDeletePage, setConfirmingDeletePage] = React.useState<Page | null>(null);
  const [pagesExpanded, setPagesExpanded] = React.useState(false);

  const showPageList =
    pages.length > 1 || selectedPage?.title || renamingPageId != null || product.native_type === "commission";

  const [insertMenuState, setInsertMenuState] = React.useState<"open" | "inputs" | null>(null);
  const initialValue = React.useMemo(() => selectedPage?.description ?? "", [selectedPageId]);

  const onSelectFiles = (ids: string[]) => {
    if (!editor) return;
    if (ids.length > 1) {
      const fileEmbedSchema = assertDefined(editor.view.state.schema.nodes[FileEmbed.name]);
      editor.commands.insertFileEmbedGroup({
        content: ids.map((id) => fileEmbedSchema.create({ id, uid: GuidGenerator.generate() })),
        pos: getInsertAtFromSelection(editor.state.selection),
      });
    } else if (ids[0]) {
      editor.commands.insertContentAt(getInsertAtFromSelection(editor.state.selection), {
        type: FileEmbed.name,
        attrs: { id: ids[0], uid: GuidGenerator.generate() },
      });
    }
  };

  const uploader = assertDefined(useEvaporateUploader());
  const s3UploadConfig = useS3UploadConfig();

  const uploadFiles = (files: File[]) => {
    const fileEntries = files.map((file) => {
      const id = FileUtils.generateGuid();
      const { s3key, fileUrl } = s3UploadConfig.generateS3KeyForUpload(id, file.name);
      const mimeType = getMimeType(file.name);
      const extension = FileUtils.getFileExtension(file.name).toUpperCase();
      const fileStatus: FileEntry["status"] = {
        type: "unsaved",
        uploadStatus: { type: "uploading", progress: { percent: 0, bitrate: 0 } },
        url: URL.createObjectURL(file),
      };
      const fileEntry: FileEntry = {
        display_name: FileUtils.getFileNameWithoutExtension(file.name),
        extension,
        description: null,
        file_size: file.size,
        is_pdf: extension === "PDF",
        pdf_stamp_enabled: false,
        is_streamable: FileUtils.isFileExtensionStreamable(extension),
        stream_only: false,
        is_transcoding_in_progress: false,
        id,
        subtitle_files: [],
        url: fileUrl,
        status: fileStatus,
        thumbnail: null,
      };

      const status = uploader.scheduleUpload({
        cancellationKey: `file_${id}`,
        name: s3key,
        file,
        mimeType,
        onComplete: () => {
          fileStatus.uploadStatus = { type: "uploaded" };
          updateProduct("files", [...product.files]);
        },
        onProgress: (progress) => {
          fileStatus.uploadStatus = { type: "uploading", progress };
          updateProduct("files", [...product.files]);
        },
      });

      if (typeof status === "string") {
        showAlert(status, "error");
      }
      return fileEntry;
    });

    updateProduct("files", [...product.files, ...fileEntries]);
    onSelectFiles(fileEntries.map((file) => file.id));
  };

  const uploadFileInput = (input: HTMLInputElement) => {
    if (!input.files?.length) return;
    uploadFiles([...input.files]);
    input.value = "";
  };

  const fileEmbedGroupConfig = useRefToLatest({
    productId: id,
    variantId: selectedVariantId,
    prepareDownload: () => Promise.resolve(save()),
    filesById,
  });

  const fileEmbedConfig = useRefToLatest<FileEmbedConfig>({ filesById });
  const uploadFilesRef = useRefToLatest(uploadFiles);
  const contentEditorExtensions = extensions(id, [
    FileEmbedGroup.configure({ getConfig: () => fileEmbedGroupConfig.current }),
    FileEmbed.configure({ getConfig: () => fileEmbedConfig.current }),
  ]);
  const editor = useRichTextEditor({
    ariaLabel: "Content editor",
    placeholder: "Enter the content you want to sell. Upload your files or start typing.",
    initialValue,
    editable: true,
    extensions: contentEditorExtensions,
    onInputNonImageFiles: (files) => uploadFilesRef.current(files),
  });

  const updateContentRef = useRefToLatest(() => {
    if (!editor) return;

    const fragment = DOMSerializer.fromSchema(editor.schema).serializeFragment(editor.state.doc.content);
    const newFiles: FileEntry[] = [];
    fragment.querySelectorAll("file-embed[url]").forEach((node) => {
      const file = existingFiles.find(
        (file) => file.id === node.getAttribute("id") || file.url === node.getAttribute("url"),
      );
      if (file) {
        node.setAttribute("id", file.id);
        if (node.hasAttribute("url")) {
          newFiles.push(file);
          node.removeAttribute("url");
        }
      } else {
        node.remove();
      }
    });
    if (newFiles.length > 0) {
      updateProduct("files", [...product.files.filter((f) => !newFiles.includes(f)), ...newFiles]);
    }
    const description = generateJSON(
      new XMLSerializer().serializeToString(fragment),
      baseEditorOptions(contentEditorExtensions).extensions,
    );

    if (selectedPage) updatePages(pages.map((page) => (page === selectedPage ? { ...page, description } : page)));
    else addPage(description);
  });

  const handleCreatePageClick = () => {
    setPagesExpanded(true);
    setRenamingPageId((pages.length > 1 || selectedPage?.title ? addPage() : (selectedPage ?? addPage())).id);
  };

  React.useEffect(() => {
    if (!editor) return;

    const updateContent = () => updateContentRef.current();
    editor.on("update", updateContent);
    editor.on("blur", updateContent);
    return () => {
      editor.off("update", updateContent);
      editor.off("blur", updateContent);
    };
  }, [editor]);

  const pageIcons = React.useMemo(
    () =>
      new Map(
        editor
          ? pages.map((page) => {
              const description = editor.schema.nodeFromJSON(page.description);
              return [
                page.id,
                generatePageIcon({
                  hasLicense: findChildren(description, (node) => node.type.name === LicenseKey.name).length > 0,
                  fileIds: findChildren(description, (node) => node.type.name === FileEmbed.name).map(({ node }) =>
                    String(node.attrs.id),
                  ),
                  allFiles: product.files,
                }),
              ] as const;
            })
          : [],
      ),
    [pages],
  );

  const findPageWithNode = (type: string) =>
    editor &&
    pages.find(
      (page) =>
        findChildren(editor.schema.nodeFromJSON(page.description), (node) => node.type.name === type).length > 0,
    );

  const onInsertPosts = () => {
    if (!editor) return;
    if (selectedPage?.description && editor.$node(Posts.name)) {
      showAlert("You can't insert a list of posts more than once per page", "error");
    } else {
      editor.chain().focus().insertPosts({}).run();
    }
  };

  const onInsertLicense = () => {
    const pageWithLicense = findPageWithNode(LicenseKey.name);
    if (pageWithLicense) {
      showAlert(
        pages.length > 1
          ? `The license key has already been added to "${titleWithFallback(pageWithLicense.title)}"`
          : product.variants.length > 1
            ? `You can't insert more than one license key per ${product.native_type === "membership" ? "tier" : "version"}`
            : "You can't insert more than one license key",
        "error",
      );
    } else {
      editor?.chain().focus().insertLicenseKey({}).run();
    }
  };

  const [showInsertPostModal, setShowInsertPostModal] = React.useState(false);
  const [addingButton, setAddingButton] = React.useState<{ label: string; url: string } | null>(null);
  const [showEmbedModal, setShowEmbedModal] = React.useState(false);
  const [selectingExistingFiles, setSelectingExistingFiles] = React.useState<{
    selected: ExistingFileEntry[];
    query: string;
    isLoading?: boolean;
  } | null>(null);
  const dropbox = useDropbox();

  const filteredExistingFiles = React.useMemo(() => {
    if (!selectingExistingFiles) return [];
    const regex = new RegExp(escapeRegExp(selectingExistingFiles.query), "iu");
    return existingFiles.filter((file) => regex.test(file.display_name));
  }, [existingFiles, selectingExistingFiles?.query]);

  const fetchLatestExistingFiles = async () => {
    try {
      const [response] = await Promise.all([
        request({
          method: "GET",

          url: Routes.internal_product_existing_product_files_path(unique_permalink),
          accept: "json",
        }),
        new Promise((resolve) => setTimeout(resolve, 250)),
      ]);
      if (!response.ok) throw new ResponseError();
      await response.json();
      // Force a re-render so file states reflect latest server data
      updateProduct("files", [...product.files]);
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error");
    } finally {
      setSelectingExistingFiles((state) => (state ? { ...state, isLoading: false } : null));
    }
  };

  const addDropboxFiles = (files: ResponseDropboxFile[]) => {
    const [updatedFiles, nonModifiedFiles] = partition(product.files, (file) =>
      files.some(({ external_id }) => file.id === external_id),
    );
    updateProduct("files", [
      ...nonModifiedFiles,
      ...files.map((file) => {
        const existing = updatedFiles.find(({ id }) => id === file.external_id);
        const extension = FileUtils.getFileExtension(file.name).toUpperCase();
        return {
          display_name: existing?.display_name ?? FileUtils.getFileNameWithoutExtension(file.name),
          extension,
          description: existing?.description ?? null,
          file_size: file.bytes,
          is_pdf: extension === "PDF",
          pdf_stamp_enabled: false,
          is_streamable: FileUtils.isFileNameStreamable(file.name),
          stream_only: false,
          is_transcoding_in_progress: false,
          id: file.external_id,
          subtitle_files: [],
          url: file.s3_url,
          status: { type: "dropbox", externalId: file.external_id, uploadState: file.state } as const,
          thumbnail: existing?.thumbnail ?? null,
        };
      }),
    ]);
  };

  const uploadFromDropbox = () => {
    const uploadFiles = async (files: DropboxFile[]) => {
      for (const file of files) {
        try {
          const response = await uploadDropboxFile(unique_permalink, file);
          addDropboxFiles([response.dropbox_file]);
          setTimeout(() => onSelectFiles([response.dropbox_file.external_id]), 100);
        } catch (error) {
          assertResponseError(error);
          showAlert(error.message, "error");
        }
      }
    };
    if (window.___dropbox_files_picked) {
      void uploadFiles(window.___dropbox_files_picked);
      window.___dropbox_files_picked = null;
      return;
    }
    dropbox.choose({ linkType: "direct", multiselect: true, success: (files) => void uploadFiles(files) });
  };

  React.useEffect(() => {
    const interval = setInterval(
      () => void fetchDropboxFiles(unique_permalink).then(({ dropbox_files }) => addDropboxFiles(dropbox_files)),
      10000,
    );
    return () => clearInterval(interval);
  }, [editor]);

  const [showUpsellModal, setShowUpsellModal] = React.useState(false);
  const [showReviewModal, setShowReviewModal] = React.useState(false);

  const onInsertUpsell = (product: Product, variant: ProductOption | null, discount: InputtedDiscount | null) => {
    if (!editor) return;

    editor
      .chain()
      .focus()
      .insertUpsellCard({
        productId: product.id,
        variantId: variant?.id || null,
        discount: discount
          ? discount.type === "cents"
            ? { type: "fixed", cents: discount.value ?? 0 }
            : { type: "percent", percents: discount.value ?? 0 }
          : null,
      })
      .run();
    setShowUpsellModal(false);
  };

  const onInsertReviews = (reviewIds: string[]) => {
    if (!editor) return;
    for (const reviewId of reviewIds) {
      editor.chain().focus().insertReviewCard({ reviewId }).run();
    }
    setShowReviewModal(false);
  };

  const onInsertMoreLikeThis = () => {
    if (!editor) return;
    if (selectedPage?.description && editor.$node(MoreLikeThis.name)) {
      showAlert("You can't insert a More like this block more than once per page", "error");
    } else {
      editor
        .chain()
        .focus()
        .insertContent({ type: "moreLikeThis", attrs: { productId: id } })
        .run();
    }
  };

  const onInsertButton = () => {
    if (!editor) return;
    if (!addingButton) return;

    const href = validateUrl(addingButton.url);
    if (!href) return showAlert("Please enter a valid URL.", "error");
    editor
      .chain()
      .focus()
      .insertContent({
        type: "button",
        attrs: { href },
        content: [{ type: "text", text: addingButton.label || href || "" }],
      })
      .run();
    setAddingButton(null);
  };

  return (
    <>
      <div className="h-screen sm:h-full md:flex md:flex-col">
        {editor ? (
          <RichTextEditorToolbar
            color="ghost"
            className="border-b border-border px-8"
            editor={editor}
            productId={id}
            custom={
              <>
                <LinkMenuItem editor={editor} />
                <PopoverMenuItem name="Upload files" icon="upload-fill">
                  <div role="menu" aria-label="Image and file uploader">
                    <div role="menuitem" onClick={() => setShowEmbedModal(true)}>
                      <Icon name="media" />
                      <span>Embed media</span>
                    </div>
                    <label role="menuitem">
                      <input type="file" name="file" multiple onChange={(e) => uploadFileInput(e.target)} />
                      <Icon name="paperclip" />
                      <span>Computer files</span>
                    </label>
                    {existingFiles.length > 0 ? (
                      <div
                        role="menuitem"
                        onClick={() => {
                          setSelectingExistingFiles({ selected: [], query: "", isLoading: true });
                          void fetchLatestExistingFiles();
                        }}
                      >
                        <Icon name="files-earmark" />
                        <span>Existing product files</span>
                      </div>
                    ) : null}
                    <div role="menuitem" onClick={uploadFromDropbox}>
                      <Icon name="dropbox" />
                      <span>Dropbox files</span>
                    </div>
                  </div>
                </PopoverMenuItem>
                {selectingExistingFiles ? (
                  <Modal
                    open
                    onClose={() => setSelectingExistingFiles(null)}
                    title="Select existing product files"
                    footer={
                      <>
                        <Button onClick={() => setSelectingExistingFiles(null)}>Cancel</Button>
                        <Button
                          color="primary"
                          onClick={() => {
                            updateProduct("files", [...product.files, ...selectingExistingFiles.selected]);
                            onSelectFiles(selectingExistingFiles.selected.map((file) => file.id));
                            setSelectingExistingFiles(null);
                          }}
                        >
                          Select
                        </Button>
                      </>
                    }
                  >
                    <div className="flex flex-col gap-4">
                      <input
                        type="text"
                        placeholder="Find your files"
                        value={selectingExistingFiles.query}
                        onChange={(evt) =>
                          setSelectingExistingFiles({ ...selectingExistingFiles, query: evt.target.value })
                        }
                      />
                      <Rows
                        className="overflow-auto"
                        role="listbox"
                        style={{ maxHeight: "20rem", textAlign: "initial" }}
                      >
                        {selectingExistingFiles.isLoading ? (
                          <div className="flex min-h-40 justify-center">
                            <LoadingSpinner className="size-8" />
                          </div>
                        ) : (
                          filteredExistingFiles.map((file) => (
                            <Row key={file.id} role="option" className="cursor-pointer" asChild>
                              <label>
                                <RowContent>
                                  <FileKindIcon extension={file.extension} />
                                  <div>
                                    <h4>{file.display_name}</h4>
                                    <span>{`${file.attached_product_name || "N/A"} (${FileUtils.getFullFileSizeString(file.file_size ?? 0)})`}</span>
                                  </div>
                                  <input
                                    type="checkbox"
                                    checked={selectingExistingFiles.selected.includes(file)}
                                    onChange={() => {
                                      setSelectingExistingFiles({
                                        ...selectingExistingFiles,
                                        selected: selectingExistingFiles.selected.includes(file)
                                          ? selectingExistingFiles.selected.filter((id) => id !== file)
                                          : [...selectingExistingFiles.selected, file],
                                      });
                                    }}
                                    style={{ marginLeft: "auto" }}
                                  />
                                </RowContent>
                              </label>
                            </Row>
                          ))
                        )}
                      </Rows>
                    </div>
                  </Modal>
                ) : null}

                <Modal open={showEmbedModal} onClose={() => setShowEmbedModal(false)} title="Embed media">
                  <p>Paste a video link or upload images or videos.</p>
                  <Tabs variant="buttons">
                    <Tab isSelected aria-controls={`${uid}-embed-tab`} asChild>
                      <button type="button">
                        <Icon name="link" />
                        <h4>Embed link</h4>
                      </button>
                    </Tab>
                    <Tab isSelected={false} asChild>
                      <label>
                        <input
                          className="sr-only"
                          type="file"
                          accept="image/*,video/*"
                          multiple
                          onChange={(e) => {
                            if (!e.target.files) return;
                            const [images, nonImages] = partition([...e.target.files], (file) =>
                              file.type.startsWith("image"),
                            );
                            uploadImages({ view: editor.view, files: images, imageSettings });
                            uploadFiles(nonImages);
                            e.target.value = "";
                            setShowEmbedModal(false);
                          }}
                        />
                        <Icon name="upload-fill" />
                        <h4>Upload</h4>
                      </label>
                    </Tab>
                  </Tabs>
                  <div id={`${uid}-embed-tab`}>
                    <EmbedMediaForm
                      type="embed"
                      onClose={() => setShowEmbedModal(false)}
                      onEmbedReceived={(embed) => {
                        insertMediaEmbed(editor, embed);
                        setShowEmbedModal(false);
                      }}
                    />
                  </div>
                </Modal>
                <Separator aria-orientation="vertical" />
                <Popover
                  open={insertMenuState != null}
                  onOpenChange={(open) => setInsertMenuState(open ? "open" : null)}
                >
                  <PopoverTrigger className="toolbar-item all-unset">
                    Insert <Icon name="outline-cheveron-down" />
                  </PopoverTrigger>
                  <PopoverContent sideOffset={4} className="border-0 p-0 shadow-none">
                    <div role="menu" onClick={() => setInsertMenuState(null)}>
                      {insertMenuState === "inputs" ? (
                        <>
                          <div
                            role="menuitem"
                            onClick={(e) => {
                              e.stopPropagation();
                              setInsertMenuState("open");
                            }}
                          >
                            <Icon name="outline-cheveron-left" />
                            <span>Back</span>
                          </div>
                          <div role="menuitem" onClick={() => editor.chain().focus().insertShortAnswer({}).run()}>
                            <Icon name="card-text" />
                            <span>Short answer</span>
                          </div>
                          <div role="menuitem" onClick={() => editor.chain().focus().insertLongAnswer({}).run()}>
                            <Icon name="file-text" />
                            <span>Long answer</span>
                          </div>
                          <div role="menuitem" onClick={() => editor.chain().focus().insertFileUpload({}).run()}>
                            <Icon name="folder-plus" />
                            <span>Upload file</span>
                          </div>
                        </>
                      ) : (
                        <>
                          <div role="menuitem" onClick={() => setAddingButton({ label: "", url: "" })}>
                            <Icon name="button" />
                            <span>Button</span>
                          </div>
                          <div role="menuitem" onClick={() => editor.chain().focus().setHorizontalRule().run()}>
                            <Icon name="horizontal-rule" />
                            <span>Divider</span>
                          </div>
                          <div
                            role="menuitem"
                            onClick={(e) => {
                              e.stopPropagation();
                              setInsertMenuState("inputs");
                            }}
                            className="flex items-center"
                          >
                            <Icon name="input-cursor-text" />
                            <span>Input</span>
                            <Icon name="outline-cheveron-right" className="ml-auto" />
                          </div>
                          <div role="menuitem" onClick={onInsertMoreLikeThis}>
                            <Icon name="grid" />
                            <span>More like this</span>
                          </div>
                          <div role="menuitem" onClick={onInsertPosts}>
                            <Icon name="file-earmark-medical" />
                            <span>List of posts</span>
                          </div>
                          <div role="menuitem" onClick={onInsertLicense}>
                            <Icon name="outline-key" />
                            <span>License key</span>
                          </div>
                          <div role="menuitem" onClick={() => setShowInsertPostModal(true)}>
                            <Icon name="twitter" />
                            <span>Twitter post</span>
                          </div>
                          <div
                            role="menuitem"
                            onClick={(e) => {
                              e.stopPropagation();
                              setShowUpsellModal(true);
                            }}
                          >
                            <Icon name="cart-plus" />
                            <span>Upsell</span>
                          </div>
                          <div
                            role="menuitem"
                            onClick={(e) => {
                              e.stopPropagation();
                              setShowReviewModal(true);
                            }}
                          >
                            <Icon name="solid-star" />
                            <span>Review</span>
                          </div>
                        </>
                      )}
                    </div>
                  </PopoverContent>
                </Popover>
                <Separator aria-orientation="vertical" />
                <button className="toolbar-item cursor-pointer all-unset" onClick={handleCreatePageClick}>
                  <Icon name="plus" /> Page
                </button>
              </>
            }
          />
        ) : null}
        <PageListLayout
          className="md:h-auto! md:flex-1"
          pageList={
            !isDesktop && !showPageList ? null : (
              <div className="flex flex-col gap-4">
                {showPageList ? (
                  <ReactSortable
                    draggable="[role=tab]"
                    handle="[aria-grabbed]"
                    tag={PageList}
                    list={pages.map((page) => ({ ...page, id: page.id }))}
                    setList={updatePages}
                  >
                    <>
                      {isDesktop ? null : (
                        <PageListItem asChild className="tailwind-override text-left">
                          <button className="cursor-pointer all-unset" onClick={() => setPagesExpanded(!pagesExpanded)}>
                            <span className="flex-1">
                              <strong>Table of contents:</strong> {titleWithFallback(selectedPage?.title)}
                            </span>

                            <Icon name={pagesExpanded ? "outline-cheveron-down" : "outline-cheveron-right"} />
                          </button>
                        </PageListItem>
                      )}
                      {isDesktop || pagesExpanded ? (
                        <>
                          {pages.map((page) => (
                            <PageTab
                              key={page.id}
                              page={page}
                              selected={page === selectedPage}
                              icon={pageIcons.get(page.id) ?? "file-text"}
                              dragging={!!page.chosen}
                              renaming={page.id === renamingPageId}
                              setRenaming={(renaming) => setRenamingPageId(renaming ? page.id : null)}
                              onClick={() => {
                                setSelectedPageId(page.id);
                                if (!isDesktop) setPagesExpanded(false);
                              }}
                              onUpdate={(title) =>
                                updatePages(
                                  pagesRef.current.map((existing) =>
                                    existing.id === page.id ? { ...existing, title } : existing,
                                  ),
                                )
                              }
                              onDelete={() => setConfirmingDeletePage(page)}
                            />
                          ))}
                          {product.native_type === "commission" ? (
                            <WithTooltip
                              tip="Commission files will appear on this page upon completion"
                              position="bottom"
                            >
                              <PageTab
                                page={{
                                  id: "",
                                  title: "Downloads",
                                  description: {
                                    type: "doc",
                                    content: [],
                                  },
                                  updated_at: pages[0]?.updated_at ?? new Date().toString(),
                                }}
                                selected={false}
                                icon="file-arrow-down"
                                dragging={false}
                                renaming={false}
                                onClick={() => {}}
                                onUpdate={() => {}}
                                onDelete={() => {}}
                                setRenaming={() => {}}
                                disabled
                              />
                            </WithTooltip>
                          ) : null}
                          <PageListItem asChild className="tailwind-override text-left">
                            <button
                              className="add-page"
                              onClick={(e) => {
                                e.preventDefault();
                                handleCreatePageClick();
                              }}
                            >
                              <Icon name="plus" />
                              <span className="flex-1">Add another page</span>
                            </button>
                          </PageListItem>
                        </>
                      ) : null}
                    </>
                  </ReactSortable>
                ) : null}
                {isDesktop ? (
                  <>
                    <Card>
                      <ReviewForm
                        permalink=""
                        purchaseId=""
                        review={null}
                        preview
                        className="flex flex-wrap items-center justify-between gap-4 p-4"
                      />
                    </Card>
                    <Card>
                      {product.native_type === "membership" ? (
                        <CardContent asChild details>
                          <details>
                            <summary className="grow grid-flow-col grid-cols-[1fr_auto] before:col-start-2" inert>
                              Membership
                            </summary>
                          </details>
                        </CardContent>
                      ) : null}
                      <CardContent asChild details>
                        <details>
                          <summary inert className="grow grid-flow-col grid-cols-[1fr_auto] before:col-start-2">
                            Receipt
                          </summary>
                        </details>
                      </CardContent>
                      <CardContent asChild details>
                        <details>
                          <summary inert className="grow grid-flow-col grid-cols-[1fr_auto] before:col-start-2">
                            Library
                          </summary>
                        </details>
                      </CardContent>
                    </Card>
                    <EntityInfo
                      entityName={selectedVariant ? `${product.name} - ${selectedVariant.name}` : product.name}
                      creator={seller}
                    />
                  </>
                ) : null}
              </div>
            )
          }
        >
          <EditorContent className="rich-text grid h-full flex-1" editor={editor} data-gumroad-ignore />
        </PageListLayout>
      </div>
      {confirmingDeletePage !== null ? (
        <Modal
          open
          onClose={() => setConfirmingDeletePage(null)}
          title="Delete page?"
          footer={
            <>
              <Button onClick={() => setConfirmingDeletePage(null)}>No, cancel</Button>
              <Button
                color="danger"
                onClick={() => {
                  if (!editor) return;
                  updatePages(pages.filter((page) => page !== confirmingDeletePage));
                  setConfirmingDeletePage(null);
                }}
              >
                Yes, delete
              </Button>
            </>
          }
        >
          Are you sure you want to delete the page "{titleWithFallback(confirmingDeletePage.title)}"? Existing customers
          will lose access to this content. This action cannot be undone.
        </Modal>
      ) : null}
      {editor ? (
        <>
          <Modal open={showInsertPostModal} onClose={() => setShowInsertPostModal(false)} title="Insert Twitter post">
            <EmbedMediaForm
              type="twitter"
              onClose={() => setShowInsertPostModal(false)}
              onEmbedReceived={(data) => {
                insertMediaEmbed(editor, data);
                setShowInsertPostModal(false);
              }}
            />
          </Modal>
          <Modal
            open={addingButton != null}
            onClose={() => setAddingButton(null)}
            title="Insert button"
            footer={
              <>
                <Button onClick={() => setAddingButton(null)}>Cancel</Button>
                <Button color="primary" onClick={onInsertButton}>
                  Insert
                </Button>
              </>
            }
          >
            <input
              type="text"
              placeholder="Enter text"
              autoFocus={addingButton != null}
              value={addingButton?.label ?? ""}
              onChange={(el) => setAddingButton({ label: el.target.value, url: addingButton?.url ?? "" })}
              onKeyDown={(el) => {
                if (el.key === "Enter") onInsertButton();
              }}
            />
            <input
              type="text"
              placeholder="Enter URL"
              value={addingButton?.url ?? ""}
              onChange={(el) => setAddingButton({ label: addingButton?.label ?? "", url: el.target.value })}
              onKeyDown={(el) => {
                if (el.key === "Enter") onInsertButton();
              }}
            />
          </Modal>
        </>
      ) : null}
      <UpsellSelectModal isOpen={showUpsellModal} onClose={() => setShowUpsellModal(false)} onInsert={onInsertUpsell} />
      {id ? (
        <TestimonialSelectModal
          isOpen={showReviewModal}
          onClose={() => setShowReviewModal(false)}
          onInsert={onInsertReviews}
          productId={id}
        />
      ) : null}
    </>
  );
};

export default function ContentPage() {
  const props = usePage<ContentPageProps>().props;
  const currentSeller = useCurrentSeller();
  if (!currentSeller) return null;

  const { product, existing_files, aws_access_key_id, s3_url, user_id, id, unique_permalink } = props;

  const form = useForm<ProductType>({
    ...product,
    files: product.files,
  });

  const [contentUpdates, setContentUpdates] = React.useState<{ uniquePermalinkOrVariantIds: string[] } | null>(null);

  const [selectedVariantId, setSelectedVariantId] = React.useState<string | null>(() => {
    if (!product.has_same_rich_content_for_all_variants) {
      const firstVariant = product.variants[0];
      return firstVariant ? firstVariant.id : null;
    }

    return null;
  });

  const [confirmingDiscardVariantContent, setConfirmingDiscardVariantContent] = React.useState(false);

  const selectedVariant = form.data.variants.find((variant) => variant.id === selectedVariantId);

  const setHasSameRichContent = (value: boolean) => {
    const nt = form.data.native_type;
    if (value) {
      if (nt === "membership") {
        const variants = form.data.variants; // Tier[]
        const newVariants = variants.map((v) => ({ ...v, rich_content: [] }));
        form.setData("variants", newVariants);
      } else if (nt === "call") {
        const variants = form.data.variants; // Duration[]
        const newVariants = variants.map((v) => ({ ...v, rich_content: [] }));
        form.setData("variants", newVariants);
      } else {
        const variants = form.data.variants; // Version[]
        const newVariants = variants.map((v) => ({ ...v, rich_content: [] }));
        form.setData("variants", newVariants);
      }
      form.setData("rich_content", selectedVariant?.rich_content ?? form.data.rich_content);
      form.setData("has_same_rich_content_for_all_variants", true);
    } else {
      if (nt === "membership") {
        const variants = form.data.variants; // Tier[]
        const newVariants = variants.map((v) => ({
          ...v,
          rich_content: form.data.rich_content.length > 0 ? form.data.rich_content : v.rich_content,
        }));
        form.setData("variants", newVariants);
      } else if (nt === "call") {
        const variants = form.data.variants; // Duration[]
        const newVariants = variants.map((v) => ({
          ...v,
          rich_content: form.data.rich_content.length > 0 ? form.data.rich_content : v.rich_content,
        }));
        form.setData("variants", newVariants);
      } else {
        const variants = form.data.variants; // Version[]
        const newVariants = variants.map((v) => ({
          ...v,
          rich_content: form.data.rich_content.length > 0 ? form.data.rich_content : v.rich_content,
        }));
        form.setData("variants", newVariants);
      }
      form.setData("rich_content", []);
      form.setData("has_same_rich_content_for_all_variants", false);
    }
  };

  const filesById = React.useMemo(
    () => new Map(form.data.files.map((file) => [file.id, { ...file, url: getDownloadUrl(id, file) }])),
    [form.data.files, id],
  );

  const handleSave = () => {
    form.patch(Routes.products_edit_content_path(unique_permalink), {
      preserveScroll: true,
      onSuccess: () => {
        setContentUpdates({
          uniquePermalinkOrVariantIds: [unique_permalink],
        });
      },
    });
  };

  const handleSaveBeforeNavigate = (targetUrl: string) => {
    if (!form.isDirty) return false;
    form.transform((data) => ({
      ...data,
      redirect_to: targetUrl,
    }));
    form.patch(Routes.products_edit_content_path(unique_permalink), { preserveScroll: true });
    return true;
  };

  const updateProductKV: UpdateProductKV = (key, value) => {
    const setters: { [K in UpdateProductKey]: (val: ProductType[K]) => void } = {
      files: (val) => form.setData("files", val),
      variants: (val) => form.setData("variants", val),
      rich_content: (val) => form.setData("rich_content", val),
      has_same_rich_content_for_all_variants: (val) => form.setData("has_same_rich_content_for_all_variants", val),
    };
    setters[key](value);
  };

  const { s3UploadConfig, evaporateUploader } = useConfigureEvaporate({ aws_access_key_id, s3_url, user_id });
  const imageSettings = useImageUploadSettings();

  const loadedPostsData = React.useRef(
    new Map<string | null, { posts: Post[]; total: number; next_page: number | null }>(),
  );
  const [loadingPostsCount, setLoadingPostsCount] = React.useState(0);
  const postsDataForEditingId = loadedPostsData.current.get(selectedVariantId);
  const fetchMorePosts = async (refresh?: boolean) => {
    const page = refresh ? 1 : postsDataForEditingId?.next_page;
    if (page === null) return;
    setLoadingPostsCount((count) => ++count);
    try {
      const response = await request({
        method: "GET",
        url: Routes.internal_product_product_posts_path(unique_permalink, {
          params: { page: page ?? 1, variant_id: selectedVariantId },
        }),
        accept: "json",
      });
      if (!response.ok) throw new ResponseError();
      const parsedResponse = cast<{ posts: Post[]; total: number; next_page: number | null }>(await response.json());
      loadedPostsData.current.set(
        selectedVariantId,
        refresh
          ? parsedResponse
          : {
              posts: [...(postsDataForEditingId?.posts ?? []), ...parsedResponse.posts],
              total: parsedResponse.total,
              next_page: parsedResponse.next_page,
            },
      );
    } finally {
      setLoadingPostsCount((count) => --count);
    }
  };
  const postsContext = {
    posts: postsDataForEditingId?.posts || null,
    total: postsDataForEditingId?.total || 0,
    isLoading: loadingPostsCount > 0,
    hasMorePosts: postsDataForEditingId?.next_page !== null,
    fetchMorePosts,
    productPermalink: unique_permalink,
  };

  const licenseInfo = {
    licenseKey: "6F0E4C97-B72A4E69-A11BF6C4-AF6517E7",

    isMultiSeatLicense: product.native_type === "membership" ? product.is_multiseat_license : null,
    seats: product.is_multiseat_license ? 5 : null,
    onIsMultiSeatLicenseChange: (value: boolean) => form.setData("is_multiseat_license", value),
    productId: id,
  };

  return (
    <PostsProvider value={postsContext}>
      <LicenseProvider value={licenseInfo}>
        <EvaporateUploaderProvider value={evaporateUploader}>
          <S3UploadConfigProvider value={s3UploadConfig}>
            <Layout
              preview={
                <ProductPreview
                  product={form.data}
                  id={id}
                  uniquePermalink={unique_permalink}
                  currencyType={props.currency_type}
                  ratings={props.ratings}
                  seller_refund_policy_enabled={props.seller_refund_policy_enabled}
                  seller_refund_policy={props.seller_refund_policy}
                />
              }
              currentTab="content"
              onSave={handleSave}
              isSaving={form.processing}
              contentUpdates={contentUpdates}
              setContentUpdates={setContentUpdates}
              onBeforeNavigate={handleSaveBeforeNavigate}
              headerActions={
                form.data.variants.length > 0 ? (
                  <>
                    <hr className="relative left-1/2 my-2 w-screen max-w-none -translate-x-1/2 border-border lg:hidden" />
                    <ComboBox<Variant>
                      multiple
                      input={(props) => (
                        <div {...props} className="input h-full min-h-auto" aria-label="Select a version">
                          <span className="fake-input text-singleline">
                            {selectedVariant && !form.data.has_same_rich_content_for_all_variants
                              ? `Editing: ${selectedVariant.name || "Untitled"}`
                              : "Editing: All versions"}
                          </span>
                          <Icon name="outline-cheveron-down" />
                        </div>
                      )}
                      options={form.data.variants}
                      option={(item, props, index) => (
                        <>
                          <div
                            {...props}
                            onClick={(e) => {
                              props.onClick?.(e);
                              setSelectedVariantId(item.id);
                            }}
                            aria-selected={item.id === selectedVariantId}
                            inert={form.data.has_same_rich_content_for_all_variants}
                          >
                            <div>
                              <h4>{item.name || "Untitled"}</h4>
                              {item.id === selectedVariant?.id ? (
                                <small>Editing</small>
                              ) : form.data.has_same_rich_content_for_all_variants || item.rich_content.length ? (
                                <small>
                                  Last edited on{" "}
                                  {formatDate(
                                    (form.data.has_same_rich_content_for_all_variants
                                      ? form.data.rich_content
                                      : item.rich_content
                                    ).reduce<Date | null>((acc: Date | null, item: Page) => {
                                      const date = parseISO(item.updated_at);
                                      return acc && acc > date ? acc : date;
                                    }, null) ?? new Date(),
                                  )}
                                </small>
                              ) : (
                                <small className="text-muted">No content yet</small>
                              )}
                            </div>
                          </div>
                          {index === form.data.variants.length - 1 ? (
                            <div className="option">
                              <label style={{ alignItems: "center" }}>
                                <input
                                  type="checkbox"
                                  checked={form.data.has_same_rich_content_for_all_variants}
                                  onChange={() => {
                                    if (
                                      !form.data.has_same_rich_content_for_all_variants &&
                                      form.data.variants.length > 1
                                    )
                                      return setConfirmingDiscardVariantContent(true);
                                    setHasSameRichContent(!form.data.has_same_rich_content_for_all_variants);
                                  }}
                                />
                                <small>Use the same content for all versions</small>
                              </label>
                            </div>
                          ) : null}
                        </>
                      )}
                    />
                  </>
                ) : null
              }
            >
              <ContentTabContent
                selectedVariantId={selectedVariantId}
                product={form.data}
                updateProduct={updateProductKV}
                existingFiles={existing_files}
                save={handleSave}
                filesById={filesById}
                seller={{
                  id: currentSeller.id,
                  name: currentSeller.name || "",
                  profile_url: currentSeller.subdomain || "",
                  avatar_url: currentSeller.avatarUrl,
                }}
                imageSettings={imageSettings}
                id={id}
                unique_permalink={unique_permalink}
              />
            </Layout>
            <Modal
              open={confirmingDiscardVariantContent}
              onClose={() => setConfirmingDiscardVariantContent(false)}
              title="Discard content from other versions?"
              footer={
                <>
                  <Button onClick={() => setConfirmingDiscardVariantContent(false)}>No, cancel</Button>
                  <Button
                    color="danger"
                    onClick={() => {
                      setHasSameRichContent(true);
                      setConfirmingDiscardVariantContent(false);
                    }}
                  >
                    Yes, proceed
                  </Button>
                </>
              }
            >
              If you proceed, the content from all other versions of this product will be removed and replaced with the
              content of "{titleWithFallback(selectedVariant?.name)}".
              <strong>This action is irreversible.</strong>
            </Modal>
          </S3UploadConfigProvider>
        </EvaporateUploaderProvider>
      </LicenseProvider>
    </PostsProvider>
  );
};
