import {
  ArrowFromBottomStroke,
  ArrowUp,
  CartPlus,
  CheckCircle,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  CursorClick,
  Dropbox as DropboxIcon,
  File,
  FileDetail,
  FolderPlus,
  Grid,
  Images,
  Key,
  Link as LinkIcon,
  Minus,
  Paperclip,
  Plus,
  Rename,
  Star,
  TwitterX,
} from "@boxicons/react";
import { findChildren, generateJSON, Node as TiptapNode } from "@tiptap/core";
import { DOMSerializer } from "@tiptap/pm/model";
import { EditorContent } from "@tiptap/react";
import { parseISO } from "date-fns";
import { partition } from "lodash-es";
import * as React from "react";
import { ReactSortable } from "react-sortablejs";
import { cast } from "ts-safe-cast";

import { fetchDropboxFiles, ResponseDropboxFile, uploadDropboxFile } from "$app/data/dropbox_upload";
import { type Post } from "$app/types/workflow";
import { escapeRegExp } from "$app/utils";
import { assertDefined } from "$app/utils/assert";
import { classNames } from "$app/utils/classNames";
import { formatDate } from "$app/utils/date";
import FileUtils from "$app/utils/file";
import GuidGenerator from "$app/utils/guid_generator";
import { getMimeType } from "$app/utils/mimetypes";
import { assertResponseError, request, ResponseError } from "$app/utils/request";
import { generatePageIcon } from "$app/utils/rich_content_page";

import { Button } from "$app/components/Button";
import { InputtedDiscount } from "$app/components/CheckoutDashboard/DiscountInput";
import { ComboBox } from "$app/components/ComboBox";
import { PageList, PageListItem, PageListLayout } from "$app/components/Download/PageListLayout";
import { EntityInfo } from "$app/components/DownloadPage/Layout";
import { EvaporateUploaderProvider, useEvaporateUploader } from "$app/components/EvaporateUploader";
import { FileKindIcon } from "$app/components/FileRowContent";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Modal } from "$app/components/Modal";
import { Popover, PopoverClose, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { FileEmbedGroup } from "$app/components/ProductEdit/ContentTab/FileEmbedGroup";
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
import { TestimonialSelectModal } from "$app/components/TestimonialSelectModal";
import { FileUpload } from "$app/components/TiptapExtensions/FileUpload";
import { uploadImages } from "$app/components/TiptapExtensions/Image";
import { LicenseKey, LicenseProvider } from "$app/components/TiptapExtensions/LicenseKey";
import { LinkMenuItem } from "$app/components/TiptapExtensions/Link";
import { LongAnswer } from "$app/components/TiptapExtensions/LongAnswer";
import { EmbedMediaForm, ExternalMediaFileEmbed, insertMediaEmbed } from "$app/components/TiptapExtensions/MediaEmbed";
import { MoreLikeThis } from "$app/components/TiptapExtensions/MoreLikeThis";
import { MoveNode } from "$app/components/TiptapExtensions/MoveNode";
import { Posts, PostsProvider } from "$app/components/TiptapExtensions/Posts";
import { ShortAnswer } from "$app/components/TiptapExtensions/ShortAnswer";
import { UpsellCard } from "$app/components/TiptapExtensions/UpsellCard";
import { Card, CardContent } from "$app/components/ui/Card";
import { Checkbox } from "$app/components/ui/Checkbox";
import { Details, DetailsToggle } from "$app/components/ui/Details";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";
import { Menu, MenuItem } from "$app/components/ui/Menu";
import { Row, RowContent, Rows } from "$app/components/ui/Rows";
import { Tab, Tabs } from "$app/components/ui/Tabs";
import { Product, ProductOption, UpsellSelectModal } from "$app/components/UpsellSelectModal";
import { useConfigureEvaporate } from "$app/components/useConfigureEvaporate";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";
import { useRefToLatest } from "$app/components/useRefToLatest";
import { WithTooltip } from "$app/components/WithTooltip";

import { FileEmbed, FileEmbedConfig } from "./FileEmbed";
import { Page, PageTab, titleWithFallback } from "./PageTab";
import { NodeVisibilityProvider } from "./useNodeVisibility";

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

const FileUploadMenu = ({
  existingFiles,
  onEmbedMedia,
  onUploadFile,
  onSelectExistingFiles,
  onUploadFromDropbox,
}: {
  existingFiles: ExistingFileEntry[];
  onEmbedMedia: () => void;
  onUploadFile: (target: HTMLInputElement) => void;
  onSelectExistingFiles: () => void;
  onUploadFromDropbox: () => void;
}) => (
  <Menu aria-label="Image and file uploader">
    <PopoverClose asChild>
      <MenuItem onClick={onEmbedMedia}>
        <Images className="size-5" />
        <span>Embed media</span>
      </MenuItem>
    </PopoverClose>
    <PopoverClose asChild>
      <MenuItem asChild>
        <label>
          <input type="file" name="file" className="sr-only" multiple onChange={(e) => onUploadFile(e.target)} />
          <Paperclip className="size-5" />
          <span>Computer files</span>
        </label>
      </MenuItem>
    </PopoverClose>
    {existingFiles.length > 0 ? (
      <PopoverClose asChild>
        <MenuItem onClick={onSelectExistingFiles}>
          <File className="size-5" />
          <span>Existing product files</span>
        </MenuItem>
      </PopoverClose>
    ) : null}
    <PopoverClose asChild>
      <MenuItem onClick={onUploadFromDropbox}>
        <DropboxIcon pack="brands" className="size-5" />
        <span>Dropbox files</span>
      </MenuItem>
    </PopoverClose>
  </Menu>
);

const ContentTabContent = ({ selectedVariantId }: { selectedVariantId: string | null }) => {
  const { id, product, updateProduct, seller, save, existingFiles, setExistingFiles, uniquePermalink, filesById } =
    useProductEditContext();
  const uid = React.useId();
  const scrollContainerRef = React.useRef<HTMLDivElement>(null);
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
          updateProduct((product) => {
            product.files = [...product.files];
          });
        },
        onProgress: (progress) => {
          fileStatus.uploadStatus = { type: "uploading", progress };
          updateProduct((product) => {
            product.files = [...product.files];
          });
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
    if (newFiles.length > 0) {
      updateProduct({ files: [...product.files.filter((f) => !newFiles.includes(f)), ...newFiles] });
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
      const [updatedFiles, nonModifiedFiles] = partition(product.files, (file) =>
        files.some(({ external_id }) => file.id === external_id),
      );
      product.files = [
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
                <PopoverMenuItem name="Upload files" icon={<ArrowFromBottomStroke pack="filled" className="size-5" />}>
                  <FileUploadMenu
                    existingFiles={existingFiles}
                    onEmbedMedia={() => setShowEmbedModal(true)}
                    onUploadFile={uploadFileInput}
                    onSelectExistingFiles={() => {
                      setSelectingExistingFiles({ selected: [], query: "", isLoading: true });
                      void fetchLatestExistingFiles();
                    }}
                    onUploadFromDropbox={uploadFromDropbox}
                  />
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
                    <div className="flex flex-col gap-4">
                      <Input
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
                              <Label>
                                <RowContent>
                                  <FileKindIcon extension={file.extension} />
                                  <div className="flex-1">
                                    <h4>{file.display_name}</h4>
                                    <span>{`${file.attached_product_name || "N/A"} (${FileUtils.getFullFileSizeString(file.file_size ?? 0)})`}</span>
                                  </div>
                                  <Checkbox
                                    checked={selectingExistingFiles.selected.includes(file)}
                                    onChange={() => {
                                      setSelectingExistingFiles({
                                        ...selectingExistingFiles,
                                        selected: selectingExistingFiles.selected.includes(file)
                                          ? selectingExistingFiles.selected.filter((id) => id !== file)
                                          : [...selectingExistingFiles.selected, file],
                                      });
                                    }}
                                    className="ml-auto"
                                  />
                                </RowContent>
                              </Label>
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
                        <LinkIcon className="size-5" />
                        <h4>Embed link</h4>
                      </button>
                    </Tab>
                    <Tab isSelected={false} asChild>
                      <Label>
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
                        <ArrowUp pack="filled" className="size-5" />
                        <h4>Upload</h4>
                      </Label>
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
                <div
                  role="separator"
                  aria-orientation="vertical"
                  className="m-2 hidden border-r border-solid border-muted sm:flex"
                />
                <Popover
                  open={insertMenuState != null}
                  onOpenChange={(open) => setInsertMenuState(open ? "open" : null)}
                >
                  <PopoverTrigger className="rounded px-2 py-1 all-unset hover:bg-active-bg">
                    Insert <ChevronDown className="size-5" />
                  </PopoverTrigger>
                  <PopoverContent sideOffset={4} className="border-0 p-0 shadow-none">
                    <Menu onClick={() => setInsertMenuState(null)}>
                      {insertMenuState === "inputs" ? (
                        <>
                          <MenuItem
                            onClick={(e) => {
                              e.stopPropagation();
                              setInsertMenuState("open");
                            }}
                          >
                            <ChevronLeft className="size-5" />
                            <span>Back</span>
                          </MenuItem>
                          <MenuItem onClick={() => editor.chain().focus().insertShortAnswer({}).run()}>
                            <FileDetail className="size-5" />
                            <span>Short answer</span>
                          </MenuItem>
                          <MenuItem onClick={() => editor.chain().focus().insertLongAnswer({}).run()}>
                            <FileDetail className="size-5" />
                            <span>Long answer</span>
                          </MenuItem>
                          <MenuItem onClick={() => editor.chain().focus().insertFileUpload({}).run()}>
                            <FolderPlus className="size-5" />
                            <span>Upload file</span>
                          </MenuItem>
                        </>
                      ) : (
                        <>
                          <MenuItem onClick={() => setAddingButton({ label: "", url: "" })}>
                            <CursorClick className="size-5" />
                            <span>Button</span>
                          </MenuItem>
                          <MenuItem onClick={() => editor.chain().focus().setHorizontalRule().run()}>
                            <Minus className="size-5" />
                            <span>Divider</span>
                          </MenuItem>
                          <MenuItem
                            onClick={(e) => {
                              e.stopPropagation();
                              setInsertMenuState("inputs");
                            }}
                            className="flex items-center"
                          >
                            <Rename />
                            <span>Input</span>
                            <ChevronRight className="ml-auto size-5" />
                          </MenuItem>
                          <MenuItem onClick={onInsertMoreLikeThis}>
                            <Grid className="size-5" />
                            <span>More like this</span>
                          </MenuItem>
                          <MenuItem onClick={onInsertPosts}>
                            <FileDetail className="size-5" />
                            <span>List of posts</span>
                          </MenuItem>
                          <MenuItem onClick={onInsertLicense}>
                            <Key className="size-5" />
                            <span>License key</span>
                          </MenuItem>
                          <MenuItem onClick={() => setShowInsertPostModal(true)}>
                            <TwitterX pack="brands" className="size-5" />
                            <span>X post</span>
                          </MenuItem>
                          <MenuItem
                            onClick={(e) => {
                              e.stopPropagation();
                              setShowUpsellModal(true);
                            }}
                          >
                            <CartPlus className="size-5" />
                            <span>Upsell</span>
                          </MenuItem>
                          <MenuItem
                            onClick={(e) => {
                              e.stopPropagation();
                              setShowReviewModal(true);
                            }}
                          >
                            <Star pack="filled" className="size-5" />
                            <span>Review</span>
                          </MenuItem>
                        </>
                      )}
                    </Menu>
                  </PopoverContent>
                </Popover>
                <div
                  role="separator"
                  aria-orientation="vertical"
                  className="m-2 hidden border-r border-solid border-muted sm:flex"
                />
                <button
                  className="cursor-pointer rounded px-2 py-1 all-unset hover:bg-active-bg"
                  onClick={handleCreatePageClick}
                >
                  <Plus className="size-5" /> Page
                </button>
              </>
            }
          />
        ) : null}
        <PageListLayout
          ref={scrollContainerRef}
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

                            {pagesExpanded ? <ChevronDown className="size-5" /> : <ChevronRight className="size-5" />}
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
                              icon={pageIcons.get(page.id) ?? "text-only"}
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
                                icon="mixed-files"
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
                              <Plus className="size-5" />
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
                          <Details>
                            <DetailsToggle chevronPosition="right" className="grow opacity-30" inert>
                              Membership
                            </DetailsToggle>
                          </Details>
                        </CardContent>
                      ) : null}
                      <CardContent asChild details>
                        <Details>
                          <DetailsToggle chevronPosition="right" className="grow opacity-30" inert>
                            Receipt
                          </DetailsToggle>
                        </Details>
                      </CardContent>
                      <CardContent asChild details>
                        <Details>
                          <DetailsToggle chevronPosition="right" className="grow opacity-30" inert>
                            Library
                          </DetailsToggle>
                        </Details>
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
          <NodeVisibilityProvider scrollRef={scrollContainerRef}>
            <div className="relative h-full flex-1">
              {editor?.isEmpty ? (
                <div className="pointer-events-none absolute inset-0 flex items-start">
                  <p className="flex flex-wrap items-center gap-1 text-muted">
                    <span>Enter the content you want to sell.</span>
                    <Popover>
                      <PopoverTrigger asChild>
                        <Button size="sm" className="pointer-events-auto">
                          Upload your files
                        </Button>
                      </PopoverTrigger>
                      <PopoverContent sideOffset={4} className="pointer-events-auto border-0 p-0 shadow-none">
                        <FileUploadMenu
                          existingFiles={existingFiles}
                          onEmbedMedia={() => setShowEmbedModal(true)}
                          onUploadFile={uploadFileInput}
                          onSelectExistingFiles={() => {
                            setSelectingExistingFiles({ selected: [], query: "", isLoading: true });
                            void fetchLatestExistingFiles();
                          }}
                          onUploadFromDropbox={uploadFromDropbox}
                        />
                      </PopoverContent>
                    </Popover>
                    <span>or start typing.</span>
                  </p>
                </div>
              ) : null}
              <EditorContent className="rich-text grid h-full flex-1" editor={editor} data-gumroad-ignore />
            </div>
          </NodeVisibilityProvider>
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
          <Modal open={showInsertPostModal} onClose={() => setShowInsertPostModal(false)} title="Insert X post">
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
            <Input
              type="text"
              placeholder="Enter text"
              autoFocus={addingButton != null}
              value={addingButton?.label ?? ""}
              onChange={(el) => setAddingButton({ label: el.target.value, url: addingButton?.url ?? "" })}
              onKeyDown={(el) => {
                if (el.key === "Enter") onInsertButton();
              }}
            />
            <Input
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
                  <>
                    <hr className="relative left-1/2 my-2 w-screen max-w-none -translate-x-1/2 border-border lg:hidden" />
                    <ComboBox<Variant>
                      input={(props) => (
                        <InputGroup {...props} className="cursor-pointer py-3" aria-label="Select a version">
                          <span className="flex-1 truncate">
                            {selectedVariant && !product.has_same_rich_content_for_all_variants
                              ? `Editing: ${selectedVariant.name || "Untitled"}`
                              : "Editing: All versions"}
                          </span>
                          <ChevronDown className="size-5" />
                        </InputGroup>
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
                            className={classNames(
                              props.className,
                              product.has_same_rich_content_for_all_variants ? "opacity-30" : undefined,
                            )}
                          >
                            <div className="flex-1">
                              <h4>{item.name || "Untitled"}</h4>
                              {item.id === selectedVariant?.id ? (
                                <small className="block">Editing</small>
                              ) : product.has_same_rich_content_for_all_variants || item.rich_content.length ? (
                                <small className="block">
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
                                <small className="block text-muted">No content yet</small>
                              )}
                            </div>
                            {item.id === selectedVariant?.id && (
                              <CheckCircle pack="filled" className="ml-auto size-5 text-success" />
                            )}
                          </div>
                          {index === product.variants.length - 1 ? (
                            <div className="flex cursor-pointer items-center px-4 py-2">
                              <Label className="items-center">
                                <Checkbox
                                  checked={product.has_same_rich_content_for_all_variants}
                                  onChange={() => {
                                    if (!product.has_same_rich_content_for_all_variants && product.variants.length > 1)
                                      return setConfirmingDiscardVariantContent(true);
                                    setHasSameRichContent(!product.has_same_rich_content_for_all_variants);
                                  }}
                                />
                                <small className="block">Use the same content for all versions</small>
                              </Label>
                            </div>
                          ) : null}
                        </>
                      )}
                    />
                  </>
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
