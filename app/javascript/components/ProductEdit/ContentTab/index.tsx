import { findChildren, generateJSON, Node as TiptapNode } from "@tiptap/core";
import { DOMSerializer } from "@tiptap/pm/model";
import { EditorContent } from "@tiptap/react";
import { parseISO } from "date-fns";
import partition from "lodash/partition";
import * as React from "react";
import { ReactSortable } from "react-sortablejs";
import { cast } from "ts-safe-cast";

import { fetchDropboxFiles, ResponseDropboxFile, uploadDropboxFile } from "$app/data/dropbox_upload";
import { Post } from "$app/data/workflows";
import { escapeRegExp } from "$app/utils";
import { assertDefined } from "$app/utils/assert";
import { formatDate } from "$app/utils/date";
import FileUtils from "$app/utils/file";
import GuidGenerator from "$app/utils/guid_generator";
import { getMimeType } from "$app/utils/mimetypes";
import { assertResponseError, request, ResponseError } from "$app/utils/request";
import { generatePageIcon } from "$app/utils/rich_content_page";

import { Button } from "$app/components/Button";
import { InputtedDiscount } from "$app/components/CheckoutDashboard/DiscountInput";
import { ComboBox } from "$app/components/ComboBox";
import { EvaporateUploaderProvider, useEvaporateUploader } from "$app/components/EvaporateUploader";
import { FileKindIcon } from "$app/components/FileRowContent";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Modal } from "$app/components/Modal";
import { Popover } from "$app/components/Popover";
import { Layout } from "$app/components/ProductEdit/Layout";
import { ExistingFileEntry, FileEntry, useProductEditContext, Variant } from "$app/components/ProductEdit/state";
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
import { S3UploadConfigProvider, useS3UploadConfig } from "$app/components/S3UploadConfig";
import { showAlert } from "$app/components/server-components/Alert";
import { EntityInfo } from "$app/components/server-components/DownloadPage/Layout";
import { TestimonialSelectModal } from "$app/components/TestimonialSelectModal";
import { FileEmbedGroup } from "$app/components/TiptapExtensions/FileEmbedGroup";
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
import { UpsellSelectModal, Product, ProductOption } from "$app/components/UpsellSelectModal";
import { useConfigureEvaporate } from "$app/components/useConfigureEvaporate";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";
import { useRefToLatest } from "$app/components/useRefToLatest";
import { WithTooltip } from "$app/components/WithTooltip";

import { FileEmbed, FileEmbedConfig, getDownloadUrl } from "./FileEmbed";
import { Page, PageTab, titleWithFallback } from "./PageTab";

const PageTabList = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement>>(({ children }, ref) => (
  <div ref={ref} role="tablist" className="pagelist">
    {children}
  </div>
));
PageTabList.displayName = "PageTabList";

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

const ContentTabContent = ({ selectedVariantId }: { selectedVariantId: string | null }) => {
  const { id, product, updateProduct, seller, save, existingFiles, setExistingFiles, uniquePermalink } =
    useProductEditContext();
  const uid = React.useId();
  const isDesktop = useIsAboveBreakpoint("lg");
  const imageSettings = useImageUploadSettings();

  const selectedVariant = product.has_same_rich_content_for_all_variants
    ? null
    : product.variants.find((variant) => variant.id === selectedVariantId);
  const pages: (Page & { chosen?: boolean })[] = selectedVariant ? selectedVariant.rich_content : product.rich_content;
  const pagesRef = useRefToLatest(pages);
  const updatePages = (pages: Page[]) =>
    updateProduct((product) => {
      if (selectedVariant) selectedVariant.rich_content = pages;
      else {
        product.has_same_rich_content_for_all_variants = true;
        product.rich_content = pages;
      }
    });
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
          updateProduct({});
        },
        onProgress: (progress) => {
          fileStatus.uploadStatus = { type: "uploading", progress };
          updateProduct({});
        },
      });
      if (typeof status === "string") {
        // status contains error string if any, otherwise index of file in array
        showAlert(status, "error");
      }
      return fileEntry;
    });
    updateProduct({ files: [...product.files, ...fileEntries] });
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
    prepareDownload: save,
    files: product.files.map((file) => ({ ...file, url: getDownloadUrl(id, file) })),
  });
  const fileEmbedConfig = useRefToLatest<FileEmbedConfig>({ files: product.files });
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

    // Correctly set the IDs of the file embeds copied from another product
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
    updateProduct({ files: [...product.files.filter((f) => !newFiles.includes(f)), ...newFiles] });
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
          url: Routes.internal_product_existing_product_files_path(uniquePermalink),
          accept: "json",
        }),
        // Enforce minimum loading time to prevent jarring spinner flicker UX on fast connections
        new Promise((resolve) => setTimeout(resolve, 250)),
      ]);
      if (!response.ok) throw new ResponseError();
      const parsedResponse = cast<{ existing_files: ExistingFileEntry[] }>(await response.json());
      setExistingFiles(parsedResponse.existing_files);
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error");
    } finally {
      setSelectingExistingFiles((state) => (state ? { ...state, isLoading: false } : null));
    }
  };

  const addDropboxFiles = (files: ResponseDropboxFile[]) => {
    updateProduct((product) => {
      product.files = [
        ...product.files.filter((file) => !files.some(({ external_id }) => file.id === external_id)),
        ...files.map((file) => {
          const existing = product.files.find(({ id }) => id === file.external_id);
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
      ];
    });
  };
  const uploadFromDropbox = () => {
    const uploadFiles = async (files: DropboxFile[]) => {
      for (const file of files) {
        try {
          const response = await uploadDropboxFile(uniquePermalink, file);
          addDropboxFiles([response.dropbox_file]);
          setTimeout(() => onSelectFiles([response.dropbox_file.external_id]), 100);
        } catch (error) {
          assertResponseError(error);
          showAlert(error.message, "error");
        }
      }
    };
    // hack for use in E2E tests
    if (window.___dropbox_files_picked) {
      void uploadFiles(window.___dropbox_files_picked);
      window.___dropbox_files_picked = null;
      return;
    }
    window.Dropbox.choose({ linkType: "direct", multiselect: true, success: (files) => void uploadFiles(files) });
  };
  React.useEffect(() => {
    const interval = setInterval(
      () => void fetchDropboxFiles(uniquePermalink).then(({ dropbox_files }) => addDropboxFiles(dropbox_files)),
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
      <main className="product-content h-screen sm:h-full">
        {editor ? (
          <RichTextEditorToolbar
            editor={editor}
            productId={id}
            custom={
              <>
                <LinkMenuItem editor={editor} />
                <PopoverMenuItem name="Upload files" icon="upload-fill">
                  {(close) => (
                    <div role="menu" aria-label="Image and file uploader" onClick={close}>
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
                  )}
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
                            updateProduct({ files: [...product.files, ...selectingExistingFiles.selected] });
                            onSelectFiles(selectingExistingFiles.selected.map((file) => file.id));
                            setSelectingExistingFiles(null);
                          }}
                        >
                          Select
                        </Button>
                      </>
                    }
                  >
                    <div className="paragraphs">
                      <input
                        type="text"
                        placeholder="Find your files"
                        value={selectingExistingFiles.query}
                        onChange={(evt) =>
                          setSelectingExistingFiles({ ...selectingExistingFiles, query: evt.target.value })
                        }
                      />
                      <div
                        className="rows"
                        role="listbox"
                        style={{ maxHeight: "20rem", overflow: "auto", textAlign: "initial" }}
                      >
                        {selectingExistingFiles.isLoading ? (
                          <div style={{ display: "flex", justifyContent: "center", minHeight: "10rem" }}>
                            <LoadingSpinner width="2rem" />
                          </div>
                        ) : (
                          filteredExistingFiles.map((file) => (
                            <label key={file.id} role="option" style={{ cursor: "pointer" }}>
                              <div className="content">
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
                              </div>
                            </label>
                          ))
                        )}
                      </div>
                    </div>
                  </Modal>
                ) : null}

                <Modal open={showEmbedModal} onClose={() => setShowEmbedModal(false)} title="Embed media">
                  <p>Paste a video link or upload images or videos.</p>
                  <div role="tablist" className="tab-buttons small">
                    <Button role="tab" aria-controls={`${uid}-embed-tab`} aria-selected>
                      <Icon name="link" />
                      <h4>Embed link</h4>
                    </Button>
                    <label className="button" role="tab">
                      <input
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
                  </div>
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
                <div role="separator" aria-orientation="vertical" />
                <Popover
                  trigger={
                    <div className="toolbar-item">
                      Insert <Icon name="outline-cheveron-down" />
                    </div>
                  }
                  open={insertMenuState != null}
                  onToggle={(open) => setInsertMenuState(open ? "open" : null)}
                >
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
                          <span className="icon icon-button" />
                          <span>Button</span>
                        </div>
                        <div role="menuitem" onClick={() => editor.chain().focus().setHorizontalRule().run()}>
                          <span className="icon icon-horizontal-rule" />
                          <span>Divider</span>
                        </div>
                        <div
                          role="menuitem"
                          onClick={(e) => {
                            e.stopPropagation();
                            setInsertMenuState("inputs");
                          }}
                          style={{ display: "flex", alignItems: "center" }}
                        >
                          <span className="icon icon-input-cursor-text" />
                          <span>Input</span>
                          <span className="icon icon-outline-cheveron-right" style={{ marginLeft: "auto" }} />
                        </div>
                        <div role="menuitem" onClick={onInsertMoreLikeThis}>
                          <span className="icon icon-grid" />
                          <span>More like this</span>
                        </div>
                        <div role="menuitem" onClick={onInsertPosts}>
                          <span className="icon icon-file-earmark-medical" />
                          <span>List of posts</span>
                        </div>
                        <div role="menuitem" onClick={onInsertLicense}>
                          <span className="icon icon-outline-key" />
                          <span>License key</span>
                        </div>
                        <div role="menuitem" onClick={() => setShowInsertPostModal(true)}>
                          <span className="icon icon-twitter" />
                          <span>Twitter post</span>
                        </div>
                        <div
                          role="menuitem"
                          onClick={(e) => {
                            e.stopPropagation();
                            setShowUpsellModal(true);
                          }}
                        >
                          <span className="icon icon-cart-plus" />
                          <span>Upsell</span>
                        </div>
                        <div
                          role="menuitem"
                          onClick={(e) => {
                            e.stopPropagation();
                            setShowReviewModal(true);
                          }}
                        >
                          <span className="icon icon-solid-star" />
                          <span>Review</span>
                        </div>
                      </>
                    )}
                  </div>
                </Popover>
                <>
                  <div role="separator" aria-orientation="vertical" />
                  <button className="toolbar-item" onClick={handleCreatePageClick}>
                    <Icon name="plus" /> Page
                  </button>
                </>
              </>
            }
          />
        ) : null}
        <div className="has-sidebar">
          {!isDesktop && !showPageList ? null : (
            <div className="paragraphs">
              {showPageList ? (
                <ReactSortable
                  draggable="[role=tab]"
                  handle="[aria-grabbed]"
                  tag={PageTabList}
                  list={pages.map((page) => ({ ...page, id: page.id }))}
                  setList={updatePages}
                >
                  <>
                    {isDesktop ? null : (
                      <button onClick={() => setPagesExpanded(!pagesExpanded)}>
                        <span className="content">
                          <strong>Table of contents:</strong> {titleWithFallback(selectedPage?.title)}
                        </span>

                        <Icon name={pagesExpanded ? "outline-cheveron-down" : "outline-cheveron-right"} />
                      </button>
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
                        <button
                          className="add-page"
                          onClick={(e) => {
                            e.preventDefault();
                            handleCreatePageClick();
                          }}
                        >
                          <Icon name="plus" />
                          <span className="content">Add another page</span>
                        </button>
                      </>
                    ) : null}
                  </>
                </ReactSortable>
              ) : null}
              {isDesktop ? (
                <>
                  <div className="stack">
                    <ReviewForm permalink="" purchaseId="" review={null} preview />
                  </div>
                  <div className="stack">
                    {product.native_type === "membership" ? (
                      <details>
                        <summary inert>Membership</summary>
                      </details>
                    ) : null}
                    <details>
                      <summary inert>Receipt</summary>
                    </details>
                    <details>
                      <summary inert>Library</summary>
                    </details>
                  </div>
                  <EntityInfo
                    entityName={selectedVariant ? `${product.name} - ${selectedVariant.name}` : product.name}
                    creator={seller}
                  />
                </>
              ) : null}
            </div>
          )}
          <EditorContent className="rich-text" editor={editor} data-gumroad-ignore />
        </div>
      </main>
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

//TODO inline this once all the crazy providers are gone
export const ContentTab = () => {
  const { id, awsKey, s3Url, seller, product, updateProduct, uniquePermalink } = useProductEditContext();
  const [selectedVariantId, setSelectedVariantId] = React.useState(product.variants[0]?.id ?? null);
  const [confirmingDiscardVariantContent, setConfirmingDiscardVariantContent] = React.useState(false);
  const selectedVariant = product.variants.find((variant) => variant.id === selectedVariantId);

  const setHasSameRichContent = (value: boolean) => {
    if (value) {
      updateProduct((product) => {
        product.has_same_rich_content_for_all_variants = true;
        if (!product.rich_content.length) product.rich_content = selectedVariant?.rich_content ?? [];
        for (const variant of product.variants) variant.rich_content = [];
      });
    } else {
      updateProduct((product) => {
        product.has_same_rich_content_for_all_variants = false;
        if (product.rich_content.length > 0) {
          for (const variant of product.variants) variant.rich_content = product.rich_content;
          product.rich_content = [];
        }
      });
    }
  };

  const { evaporateUploader, s3UploadConfig } = useConfigureEvaporate({
    aws_access_key_id: awsKey,
    s3_url: s3Url,
    user_id: seller.id,
  });

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
        url: Routes.internal_product_product_posts_path(uniquePermalink, {
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
    productPermalink: uniquePermalink,
  };

  const licenseInfo = {
    licenseKey: "6F0E4C97-B72A4E69-A11BF6C4-AF6517E7",
    isMultiSeatLicense: product.native_type === "membership" ? product.is_multiseat_license : null,
    seats: product.is_multiseat_license ? 5 : null,
    onIsMultiSeatLicenseChange: (value: boolean) => updateProduct({ is_multiseat_license: value }),
    productId: id,
  };

  return (
    <PostsProvider value={postsContext}>
      <LicenseProvider value={licenseInfo}>
        <EvaporateUploaderProvider value={evaporateUploader}>
          <S3UploadConfigProvider value={s3UploadConfig}>
            <Layout
              headerActions={
                product.variants.length > 0 ? (
                  <div className="actions">
                    <ComboBox<Variant>
                      className="version-dropdown"
                      // TODO: Currently needed to get the icon on the selected option even though this is not multiple select. We should fix this in the design system
                      multiple
                      input={(props) => (
                        <div {...props} className="input" aria-label="Select a version">
                          <span className="fake-input text-singleline">
                            {selectedVariant && !product.has_same_rich_content_for_all_variants
                              ? `Editing: ${selectedVariant.name || "Untitled"}`
                              : "Editing: All versions"}
                          </span>
                          <Icon name="outline-cheveron-down" />
                        </div>
                      )}
                      options={product.variants}
                      option={(item, props, index) => (
                        <>
                          <div
                            {...props}
                            onClick={(e) => {
                              props.onClick?.(e);
                              setSelectedVariantId(item.id);
                            }}
                            aria-selected={item.id === selectedVariantId}
                            inert={product.has_same_rich_content_for_all_variants}
                          >
                            <div>
                              <h4>{item.name || "Untitled"}</h4>
                              {item.id === selectedVariant?.id ? (
                                <small>Editing</small>
                              ) : product.has_same_rich_content_for_all_variants || item.rich_content.length ? (
                                <small>
                                  Last edited on{" "}
                                  {formatDate(
                                    (product.has_same_rich_content_for_all_variants
                                      ? product.rich_content
                                      : item.rich_content
                                    ).reduce<Date | null>((acc, item) => {
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
                          {index === product.variants.length - 1 ? (
                            <div className="option">
                              <label style={{ alignItems: "center" }}>
                                <input
                                  type="checkbox"
                                  checked={product.has_same_rich_content_for_all_variants}
                                  onChange={() => {
                                    if (!product.has_same_rich_content_for_all_variants && product.variants.length > 1)
                                      return setConfirmingDiscardVariantContent(true);
                                    setHasSameRichContent(!product.has_same_rich_content_for_all_variants);
                                  }}
                                />
                                <small>Use the same content for all versions</small>
                              </label>
                            </div>
                          ) : null}
                        </>
                      )}
                    />
                  </div>
                ) : null
              }
            >
              <ContentTabContent selectedVariantId={selectedVariantId} />
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
