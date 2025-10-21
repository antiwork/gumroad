import { DirectUpload } from "@rails/activestorage";
import { findChildren, Node as TiptapNode } from "@tiptap/core";
import { Plugin } from "@tiptap/pm/state";
import { EditorContent, NodeViewProps, NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import cx from "classnames";
import * as React from "react";
import { Link, useLoaderData, useRevalidator } from "react-router-dom";
import { cast } from "ts-safe-cast";

import {
  WorkflowFormContext,
  Workflow,
  InstallmentDeliveryTimePeriod,
  INSTALLMENT_DELIVERY_TIME_PERIODS,
  saveWorkflowInstallments,
  Installment,
  SaveActionName,
  AbandonedCartProduct,
} from "$app/data/workflows";
import { assert, assertDefined } from "$app/utils/assert";
import { ALLOWED_EXTENSIONS } from "$app/utils/file";
import GuidGenerator from "$app/utils/guid_generator";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useAppDomain, useDomains } from "$app/components/DomainSettings";
import {
  EmailAttachments,
  FilesDispatchProvider,
  FilesProvider,
  filesReducer,
  FileState,
  isFileUploading,
  useFiles,
} from "$app/components/EmailAttachments";
import { EvaporateUploaderProvider } from "$app/components/EvaporateUploader";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { NumberInput } from "$app/components/NumberInput";
import { ImageUploadSettingsContext, RichTextEditor, useRichTextEditor } from "$app/components/RichTextEditor";
import { S3UploadConfigProvider } from "$app/components/S3UploadConfig";
import { Separator } from "$app/components/Separator";
import { showAlert } from "$app/components/server-components/Alert";
import {
  Layout,
  EditPageNavigation,
  PublishButton,
  sendToPastCustomersCheckboxLabel,
} from "$app/components/server-components/WorkflowsPage";
import {
  determineWorkflowTrigger,
  WorkflowTrigger,
} from "$app/components/server-components/WorkflowsPage/WorkflowForm";
import Placeholder from "$app/components/ui/Placeholder";
import { useConfigureEvaporate } from "$app/components/useConfigureEvaporate";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { WithTooltip } from "$app/components/WithTooltip";

type EmailFormState = {
  id: string;
  name: string;
  message: string;
  delayed_delivery_time_duration: number;
  delayed_delivery_time_period: InstallmentDeliveryTimePeriod;
  stream_only: boolean;
};
type EditableEmailFormState = Omit<EmailFormState, "id">;
type FocusedFieldInfo = {
  emailId: string;
  fieldName: null | keyof EditableEmailFormState;
};
type InvalidFieldNames = "name";
type InvalidField = { emailId: string; fieldName: InvalidFieldNames };

const WORKFLOW_EMAILS_LABELS = {
  abandoned_cart: "cart abandonment",
  legacy_audience: "becoming an audience",
  member_cancels: "membership cancellation takes effect",
  new_affiliate: "becoming an affiliate",
  new_subscriber: "becoming a subscriber",
  purchase: "purchase",
};

const ABANDONED_CART_PRODUCTS_TO_LOAD_PER_PAGE = 3;
const AbandonedCartProductsContext = React.createContext<{
  abandonedCartProducts: AbandonedCartProduct[];
  shownProductCount: number;
  setShownProductCount: React.Dispatch<React.SetStateAction<number>>;
  showAddProductCTA: boolean;
} | null>(null);
const AbandonedCartProductsProvider = AbandonedCartProductsContext.Provider;
const useAbandonedCartProducts = () => assertDefined(React.useContext(AbandonedCartProductsContext));

const WorkflowEmails = () => {
  const { context, workflow } = cast<{ context: WorkflowFormContext; workflow: Workflow }>(useLoaderData());
  const loaderDataRevalidator = useRevalidator();
  const [sendToPastCustomers, setSendToPastCustomers] = React.useState(workflow.send_to_past_customers);
  const [isSaving, setIsSaving] = React.useState(false);
  const [files, filesDispatch] = React.useReducer(filesReducer, installmentsFilesToFilesState(workflow.installments));
  const [emails, setEmails] = React.useState<EmailFormState[]>(installmentsToEmails(workflow.installments));
  const workflowTrigger = determineWorkflowTrigger(workflow);
  const isAbandonedCartWorkflow = workflowTrigger === "abandoned_cart";
  const [expandedEmailIds, setExpandedEmailIds] = React.useState<Set<string>>(
    isAbandonedCartWorkflow && emails[0] ? new Set([emails[0].id]) : new Set(),
  );
  const updateEmail = (id: string, value: Partial<EditableEmailFormState>) => {
    setEmails((prev) => prev.map((email) => (email.id === id ? { ...email, ...value } : email)));
    setFocusedFieldInfo({ emailId: id, fieldName: Object.keys(value)[0] ?? null });
    if (value.name !== undefined && invalidFields.some((invalidField) => invalidField.emailId === id)) {
      setInvalidFields((prev) => prev.filter((invalidField) => !(invalidField.emailId === id)));
    }
  };
  const [imagesUploading, setImagesUploading] = React.useState<Set<File>>(new Set());
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
            // Fetch the CDN URL for the image
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
  const { evaporateUploader, s3UploadConfig } = useConfigureEvaporate({
    aws_access_key_id: context.aws_access_key_id,
    s3_url: context.s3_url,
    user_id: context.user_id,
  });
  const handleAddEmail = () => {
    const id = GuidGenerator.generate();
    setEmails((prev) => [
      ...prev,
      {
        id,
        name: "",
        message: "<p></p>",
        files: [],
        delayed_delivery_time_duration: 0,
        delayed_delivery_time_period: "hour",
        stream_only: false,
      },
    ]);
    setExpandedEmailIds((prev) => new Set(prev).add(id));
    setFocusedFieldInfo({ emailId: id, fieldName: "name" });
  };
  const [focusedFieldInfo, setFocusedFieldInfo] = React.useState<FocusedFieldInfo | null>(null);
  const [invalidFields, setInvalidFields] = React.useState<InvalidField[]>([]);
  const [deletingEmailId, setDeletingEmailId] = React.useState<null | string>(null);
  const [shownProductCount, setShownProductCount] = React.useState(ABANDONED_CART_PRODUCTS_TO_LOAD_PER_PAGE);
  const abandonedCartProductsContextValue = React.useMemo(
    () => ({
      abandonedCartProducts: workflow.abandoned_cart_products ?? [],
      shownProductCount,
      setShownProductCount,
      showAddProductCTA:
        !workflow.seller_has_products &&
        (workflow.first_published_at ===
          null /* Once a workflow is published, there is no way to change its selected products */ ||
          ((workflow.bought_products ?? []).length === 0 &&
            (workflow.bought_variants ?? []).length === 0)) /* i.e. all products are selected */,
    }),
    [shownProductCount],
  );
  const deleteEmail = (emailId: string) => {
    setDeletingEmailId(null);
    setEmails((prev) => prev.filter((prevEmail) => prevEmail.id !== emailId));
    setExpandedEmailIds((prev) => {
      const updated = new Set(prev);
      updated.delete(emailId);
      return updated;
    });
    if (focusedFieldInfo?.emailId === emailId) setFocusedFieldInfo(null);
  };
  const validate = () => {
    const invalidFields = new Array<InvalidField>();
    emails.forEach((email) => {
      if (email.name.trim() === "") {
        invalidFields.push({ emailId: email.id, fieldName: "name" });
        setFocusedFieldInfo({ emailId: email.id, fieldName: "name" });
        setExpandedEmailIds((prev) => new Set(prev).add(email.id));
      }
    });
    setInvalidFields(invalidFields);
    return invalidFields.length === 0;
  };
  const handleSave = asyncVoid(
    async ({
      sendPreviewForEmailId,
      saveActionName = "save",
    }: { sendPreviewForEmailId?: string; saveActionName?: SaveActionName } = {}) => {
      setFocusedFieldInfo(null);

      if (!validate()) return;

      const payload = {
        workflow: {
          send_to_past_customers: sendToPastCustomers,
          save_action_name: saveActionName,
          installments: emails.map((email) => {
            const emailFiles = files.filter((file) => file.email_id === email.id);
            return {
              id: email.id,
              name: email.name,
              message: email.message,
              time_period: email.delayed_delivery_time_period,
              time_duration: email.delayed_delivery_time_duration,
              send_preview_email: email.id === sendPreviewForEmailId,
              files: emailFiles.map((file, index) => ({
                external_id: file.id,
                url: file.url,
                position: index,
                // if email is marked stream-only, all streamable files are considered stream-only
                stream_only: file.is_streamable && email.stream_only,
                subtitle_files: file.subtitle_files,
              })),
            };
          }),
        },
      };

      try {
        setIsSaving(true);
        const response = await saveWorkflowInstallments(workflow.external_id, payload);
        if (response.success) {
          if (sendPreviewForEmailId) {
            showAlert("A preview has been sent to your email.", "success");
          } else {
            showAlert(
              saveActionName === "save_and_publish"
                ? "Workflow published!"
                : saveActionName === "save_and_unpublish"
                  ? "Unpublished!"
                  : "Changes saved!",
              "success",
            );
          }
          setExpandedEmailIds((prev) => {
            const updated = new Set(prev);
            Object.entries(response.old_and_new_installment_id_mapping).forEach(([oldId, newId]) => {
              if (updated.has(oldId) && oldId !== newId) {
                updated.delete(oldId);
                updated.add(newId);
              }
            });
            return updated;
          });
          loaderDataRevalidator.revalidate();
          setEmails(installmentsToEmails(response.workflow.installments));
          filesDispatch({ type: "reset", files: installmentsFilesToFilesState(response.workflow.installments) });
        } else {
          showAlert(response.message, "error");
        }
      } catch (e) {
        assertResponseError(e);
        showAlert("Sorry, something went wrong. Please try again.", "error");
      } finally {
        setIsSaving(false);
      }
    },
  );
  const isBusy =
    isSaving ||
    imagesUploading.size > 0 ||
    files.some((file) => isFileUploading(file) || file.subtitle_files.some((subtitle) => isFileUploading(subtitle)));
  const sortedEmails = sortEmailsByDelayedDeliveryTime(emails);

  return (
    <FilesProvider value={files}>
      <AbandonedCartProductsProvider value={abandonedCartProductsContextValue}>
        <Layout
          title={workflow.name}
          navigation={<EditPageNavigation workflowExternalId={workflow.external_id} />}
          actions={
            <>
              <Link to="/workflows" className="button" inert={isBusy}>
                {workflow.published ? (
                  <>
                    <Icon name="x-square" />
                    Cancel
                  </>
                ) : (
                  <>
                    <Icon name="arrow-left" />
                    Back
                  </>
                )}
              </Link>
              <Button color="primary" disabled={isBusy} onClick={() => handleSave()}>
                Save changes
              </Button>
              <PublishButton
                isPublished={workflow.published}
                wasPublishedPreviously={!!workflow.first_published_at}
                isDisabled={isBusy}
                sendToPastCustomers={
                  isAbandonedCartWorkflow
                    ? null
                    : {
                        enabled: sendToPastCustomers,
                        toggle: setSendToPastCustomers,
                        label: sendToPastCustomersCheckboxLabel(workflowTrigger),
                      }
                }
                onClick={(saveActionName) => handleSave({ saveActionName })}
              />
            </>
          }
          preview={sortedEmails.map((email) => (
            <EmailPreview
              key={email.id}
              email={email}
              isEditing={focusedFieldInfo?.emailId === email.id}
              workflowTrigger={workflowTrigger}
              gumroadAddress={context.gumroad_address}
            />
          ))}
        >
          <S3UploadConfigProvider value={s3UploadConfig}>
            <EvaporateUploaderProvider value={evaporateUploader}>
              <ImageUploadSettingsContext.Provider value={imageSettings}>
                <FilesDispatchProvider value={filesDispatch}>
                  <section className="space-y-4 p-4 md:p-8">
                    {emails.length === 0 ? (
                      <Placeholder>
                        <h2>Create emails for your workflow</h2>
                        <h4>Users will receive workflows as email messages with links to any files you've attached.</h4>
                        <Button color="primary" onClick={handleAddEmail}>
                          Create email
                        </Button>
                      </Placeholder>
                    ) : (
                      <>
                        <div className="rows">
                          {sortedEmails.map((email) => (
                            <EmailRow
                              key={email.id}
                              email={email}
                              workflowTrigger={workflowTrigger}
                              expanded={expandedEmailIds.has(email.id)}
                              focusedFieldInfo={focusedFieldInfo}
                              invalidFieldNames={invalidFields.flatMap((invalidField) =>
                                invalidField.emailId === email.id ? invalidField.fieldName : [],
                              )}
                              toggleExpanded={() => {
                                setFocusedFieldInfo(
                                  expandedEmailIds.has(email.id) ? null : { emailId: email.id, fieldName: null },
                                );
                                setExpandedEmailIds((prev) => {
                                  const updated = new Set(prev);
                                  updated[updated.has(email.id) ? "delete" : "add"](email.id);
                                  return updated;
                                });
                              }}
                              onFocus={(fieldName: FocusedFieldInfo["fieldName"]) =>
                                setFocusedFieldInfo({ emailId: email.id, fieldName })
                              }
                              onDelete={() => setDeletingEmailId(email.id)}
                              onChange={(value) => updateEmail(email.id, value)}
                              onSendPreviewEmail={() => handleSave({ sendPreviewForEmailId: email.id })}
                              isSaving={isSaving}
                              hasUploadingImages={imagesUploading.size > 0 && email.message.includes('src="blob:')}
                            />
                          ))}
                        </div>
                        {isAbandonedCartWorkflow ? null : (
                          <div>
                            <Button color="primary" onClick={handleAddEmail}>
                              Add email
                            </Button>
                          </div>
                        )}
                      </>
                    )}
                    {deletingEmailId ? (
                      <Modal
                        open
                        allowClose
                        onClose={() => setDeletingEmailId(null)}
                        title="Delete email?"
                        footer={
                          <>
                            <Button onClick={() => setDeletingEmailId(null)}>Cancel</Button>

                            <Button color="danger" onClick={() => deleteEmail(deletingEmailId)}>
                              Delete
                            </Button>
                          </>
                        }
                      >
                        <h4>
                          Are you sure you want to delete the email "
                          {emails.find(({ id }) => id === deletingEmailId)?.name ?? ""}"? This action cannot be undone.
                        </h4>
                      </Modal>
                    ) : null}
                  </section>
                </FilesDispatchProvider>
              </ImageUploadSettingsContext.Provider>
            </EvaporateUploaderProvider>
          </S3UploadConfigProvider>
        </Layout>
      </AbandonedCartProductsProvider>
    </FilesProvider>
  );
};

type EmailRowProps = {
  email: EmailFormState;
  workflowTrigger: WorkflowTrigger;
  expanded: boolean;
  focusedFieldInfo: FocusedFieldInfo | null;
  invalidFieldNames: InvalidFieldNames[];
  toggleExpanded: () => void;
  onChange: (value: Partial<EditableEmailFormState>) => void;
  onFocus: (fieldName: FocusedFieldInfo["fieldName"]) => void;
  onDelete: () => void;
  onSendPreviewEmail: () => void;
  isSaving: boolean;
  hasUploadingImages: boolean;
};
const EmailRow = ({
  email,
  workflowTrigger,
  expanded,
  focusedFieldInfo,
  invalidFieldNames,
  toggleExpanded,
  onChange,
  onFocus,
  onDelete,
  onSendPreviewEmail,
  isSaving,
  hasUploadingImages,
}: EmailRowProps) => {
  const [editorContent, setEditorContent] = React.useState(email.message);
  const handleMessageChange = useDebouncedCallback((message: string) => onChange({ message }), 500);
  const selfRef = React.useRef<HTMLDivElement>(null);
  const nameInputRef = React.useRef<null | HTMLInputElement>(null);
  const emailFiles = useFiles((files) => files.filter(({ email_id }) => email_id === email.id));
  React.useEffect(() => {
    if (focusedFieldInfo?.emailId !== email.id) return;

    const { fieldName } = focusedFieldInfo;
    if (fieldName === "name") nameInputRef.current?.focus();
    if (fieldName !== "message" && fieldName !== "stream_only") selfRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [focusedFieldInfo]);
  React.useEffect(() => {
    if (expanded) setEditorContent(email.message);
  }, [expanded]);
  const isAbandonedCartWorkflow = workflowTrigger === "abandoned_cart";
  const isBusy =
    isSaving ||
    emailFiles.some(
      (file) => isFileUploading(file) || file.subtitle_files.some((subtitle) => isFileUploading(subtitle)),
    );

  return (
    <div ref={selfRef} aria-label="Email">
      <div className="content">
        <Icon name="envelope-fill" className="type-icon" />
        <h3>{email.name.trim() === "" ? "Untitled" : email.name}</h3>
      </div>
      <div className="actions">
        {isAbandonedCartWorkflow ? null : (
          <Button
            outline
            disabled={(expanded && hasUploadingImages) || false}
            aria-label="Edit"
            onClick={toggleExpanded}
          >
            <Icon name={expanded ? "outline-cheveron-up" : "outline-cheveron-down"} />
          </Button>
        )}
        <WithTooltip tip="Send email preview">
          <Button outline aria-label="Preview Email" disabled={isBusy} onClick={onSendPreviewEmail}>
            <Icon name="eye-fill" />
          </Button>
        </WithTooltip>
        {isAbandonedCartWorkflow ? null : (
          <WithTooltip tip="Delete">
            <Button outline color="danger" aria-label="Delete" disabled={isBusy} onClick={onDelete}>
              <Icon name="trash2" />
            </Button>
          </WithTooltip>
        )}
      </div>
      {expanded ? (
        <form className="paragraphs">
          {isAbandonedCartWorkflow ? null : (
            <div
              style={{
                display: "grid",
                gap: "var(--spacer-3)",
                gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
              }}
            >
              <NumberInput
                onChange={(value) => onChange({ delayed_delivery_time_duration: value ?? 0 })}
                value={email.delayed_delivery_time_duration}
              >
                {(inputProps) => (
                  <input
                    type="text"
                    autoComplete="off"
                    placeholder="0"
                    aria-label="Duration"
                    onFocus={() => onFocus("delayed_delivery_time_duration")}
                    {...inputProps}
                  />
                )}
              </NumberInput>
              <select
                value={email.delayed_delivery_time_period}
                aria-label="Period"
                onChange={(e) => onChange({ delayed_delivery_time_period: cast(e.target.value) })}
                onFocus={() => onFocus("delayed_delivery_time_period")}
              >
                {INSTALLMENT_DELIVERY_TIME_PERIODS.map((period) => (
                  <option key={period} value={period}>
                    {`${period}${email.delayed_delivery_time_duration === 1 ? "" : "s"} after ${WORKFLOW_EMAILS_LABELS[workflowTrigger]}`}
                  </option>
                ))}
              </select>
            </div>
          )}
          <fieldset className={cx({ danger: invalidFieldNames.includes("name") })}>
            <input
              ref={nameInputRef}
              type="text"
              placeholder="Subject"
              value={email.name}
              maxLength={255}
              onChange={(e) => onChange({ name: e.target.value })}
              onFocus={() => onFocus("name")}
            />
          </fieldset>
          <RichTextEditor
            id={email.id}
            className="textarea"
            ariaLabel="Email message"
            placeholder="Write a personalized message..."
            extensions={[...(isAbandonedCartWorkflow ? [AbandonedCartProductList] : [])]}
            initialValue={editorContent}
            onChange={handleMessageChange}
            onCreate={(editor) => editor.on("focus", () => onFocus("message"))}
          />
          {isAbandonedCartWorkflow ? null : (
            <EmailAttachments
              emailId={email.id}
              isStreamOnly={email.stream_only}
              setIsStreamOnly={(stream_only) => onChange({ stream_only })}
            />
          )}
        </form>
      ) : null}
    </div>
  );
};

const EmailPreview = ({
  email,
  isEditing,
  workflowTrigger,
  gumroadAddress,
}: {
  email: EmailFormState;
  isEditing: boolean;
  workflowTrigger: WorkflowTrigger;
  gumroadAddress: string;
}) => {
  const [pageLoaded, setPageLoaded] = React.useState(false);
  React.useEffect(() => setPageLoaded(true), []);
  const editor = useRichTextEditor({
    ariaLabel: "Email message",
    initialValue: pageLoaded ? email.message : null,
    editable: false,
    extensions: [...(workflowTrigger === "abandoned_cart" ? [AbandonedCartProductList] : [])],
  });
  const selfRef = React.useRef<HTMLDivElement>(null);
  const emailFiles = useFiles((files) => files.filter(({ email_id }) => email_id === email.id));

  React.useEffect(() => {
    if (isEditing) setTimeout(() => selfRef.current?.scrollIntoView({ behavior: "smooth" }), 500);
  });

  return (
    <section className="paragraphs" ref={selfRef}>
      <Separator>
        <div className="flex gap-2">
          <Icon name="outline-clock" />
          {email.delayed_delivery_time_duration}{" "}
          {`${email.delayed_delivery_time_period}${email.delayed_delivery_time_duration === 1 ? "" : "s"} after ${WORKFLOW_EMAILS_LABELS[workflowTrigger]}`}
        </div>
      </Separator>
      <div className="grid gap-4 rounded-sm border border-border bg-background p-4">
        <h3>{email.name.trim() === "" ? "Untitled" : email.name}</h3>
        <EditorContent className="rich-text" editor={editor} />
        {emailFiles.length > 0 ? <Button color="primary">View content</Button> : null}
        <hr />
        <div className="paragraphs" style={{ justifyItems: "center" }}>
          <p>{gumroadAddress}</p>
          <p>
            Powered by <span style={{ marginLeft: "var(--spacer-1)" }} className="logo-full" />
          </p>
        </div>
      </div>
    </section>
  );
};

const AbandonedCartProductListNodeView = (props: NodeViewProps) => {
  const appDomain = useAppDomain();
  const { abandonedCartProducts, shownProductCount, setShownProductCount, showAddProductCTA } =
    useAbandonedCartProducts();
  const tooltipUid = React.useId();
  const isPreview = !props.editor.isEditable;

  return (
    <NodeViewWrapper className="paragraphs" style={isPreview ? {} : { userSelect: "none", cursor: "not-allowed" }}>
      <div className="has-tooltip top" aria-describedby={tooltipUid} style={{ display: "grid" }}>
        {abandonedCartProducts.length > 0 ? (
          <div className="cart" role="list">
            {abandonedCartProducts.slice(0, shownProductCount).map((product) => (
              <div role="listitem" key={product.unique_permalink} style={isPreview ? {} : { pointerEvents: "none" }}>
                <section>
                  <figure style={{ margin: 0 }}>
                    {product.thumbnail_url ? (
                      <img src={product.thumbnail_url} style={{ objectFit: "initial", borderRadius: 0 }} />
                    ) : null}
                  </figure>
                  <section>
                    <h4>
                      <a
                        href={product.url}
                        target="_blank"
                        rel="noopener noreferrer nofollow"
                        tabIndex={isPreview ? undefined : -1}
                      >
                        {product.name}
                      </a>
                    </h4>
                    <footer>
                      <SellerByLine isPreview={isPreview} />
                    </footer>
                  </section>
                  <section>
                    <footer></footer>
                  </section>
                </section>
              </div>
            ))}
          </div>
        ) : (
          <Placeholder>
            {showAddProductCTA ? (
              <span>
                <a href={Routes.new_product_path()}>Add a product</a> to have it show up here
              </span>
            ) : (
              "No products selected"
            )}
          </Placeholder>
        )}
        {isPreview ? null : (
          <div role="tooltip" id={tooltipUid}>
            This cannot be deleted
          </div>
        )}
      </div>
      {abandonedCartProducts.length > shownProductCount ? (
        <button
          className="link"
          onClick={() =>
            setShownProductCount(
              shownProductCount + ABANDONED_CART_PRODUCTS_TO_LOAD_PER_PAGE > abandonedCartProducts.length
                ? abandonedCartProducts.length
                : shownProductCount + ABANDONED_CART_PRODUCTS_TO_LOAD_PER_PAGE,
            )
          }
        >
          {`and ${abandonedCartProducts.length - shownProductCount} more ${
            abandonedCartProducts.length - shownProductCount === 1 ? "product" : "products"
          }`}
        </button>
      ) : null}

      <WithTooltip tip={isPreview ? null : "This cannot be deleted"} position="top">
        <NavigationButton
          color="primary"
          href={Routes.checkout_index_url({ host: appDomain })}
          target="_blank"
          rel="noopener noreferrer nofollow"
          style={isPreview ? {} : { pointerEvents: "none" }}
          tabIndex={isPreview ? undefined : -1}
        >
          Complete checkout
        </NavigationButton>
      </WithTooltip>
    </NodeViewWrapper>
  );
};

const SellerByLine = ({ isPreview }: { isPreview: boolean }) => {
  const currentSeller = useCurrentSeller();
  const { scheme } = useDomains();
  assert(currentSeller !== null, "currentSeller is required");

  return (
    <a
      href={`${scheme}://${currentSeller.subdomain}`}
      target="_blank"
      style={{ position: "relative", display: "flex", gap: "var(--spacer-1)", alignItems: "center" }}
      rel="noopener noreferrer nofollow"
      tabIndex={isPreview ? undefined : -1}
    >
      <img className="user-avatar" src={currentSeller.avatarUrl} />
      {currentSeller.name || currentSeller.email || ""}
    </a>
  );
};

const AbandonedCartProductList = TiptapNode.create({
  name: "abandonedCartProductList",
  group: "block",
  atom: true,
  selectable: false,
  draggable: false,
  parseHTML: () => [{ tag: "product-list-placeholder" }],
  renderHTML: () => ["product-list-placeholder"],
  addNodeView() {
    return ReactNodeViewRenderer(AbandonedCartProductListNodeView);
  },
  addKeyboardShortcuts() {
    return {
      Backspace: () => {
        const { doc, tr } = this.editor.view.state;
        const lastNode = this.editor.view.state.doc.lastChild;
        if (lastNode && lastNode.textContent === "") {
          // Remove the last editable node such as a paragraph, blockquote, etc. if it's empty
          tr.delete(tr.mapping.map(doc.content.size - lastNode.nodeSize), doc.content.size);
          this.editor.view.dispatch(tr);
        }
        // Run the default Backspace commands (Ref: https://github.com/ProseMirror/prosemirror-commands/blob/2da5f6621ab684b5b3b2a2982b8f91d293d4a582/src/commands.ts#L697)
        return this.editor.chain().deleteSelection().joinBackward().selectNodeBackward().run();
      },
    };
  },
  addProseMirrorPlugins() {
    return [
      new Plugin({
        filterTransaction: (transaction) =>
          findChildren(transaction.doc, (node) => node.type.name === "abandonedCartProductList").length === 1,
      }),
    ];
  },
});

const installmentsToEmails = (installments: Installment[]): EmailFormState[] =>
  installments.map(
    ({ external_id, name, message, delayed_delivery_time_duration, delayed_delivery_time_period, stream_only }) => ({
      id: external_id,
      name,
      message,
      delayed_delivery_time_duration,
      delayed_delivery_time_period,
      stream_only,
    }),
  );

const installmentsFilesToFilesState = (installments: Installment[]): FileState[] =>
  installments.flatMap((installment) =>
    installment.files.map((file) => ({
      ...file,
      email_id: installment.external_id,
      subtitle_files: file.subtitle_files.map((subtitle) => ({
        ...subtitle,
        status: { type: "existing" },
      })),
      status: { type: "existing" },
    })),
  );

const sortEmailsByDelayedDeliveryTime = (emails: EmailFormState[]) =>
  emails.sort((a, b) => {
    const aTime = a.delayed_delivery_time_duration * delayedDeliveryTimePeriodInSeconds(a.delayed_delivery_time_period);
    const bTime = b.delayed_delivery_time_duration * delayedDeliveryTimePeriodInSeconds(b.delayed_delivery_time_period);
    return aTime - bTime;
  });

const delayedDeliveryTimePeriodInSeconds = (delayedDeliveryTimePeriod: InstallmentDeliveryTimePeriod) => {
  switch (delayedDeliveryTimePeriod) {
    case "hour":
      return 60 * 60;
    case "day":
      return 60 * 60 * 24;
    case "week":
      return 60 * 60 * 24 * 7;
    case "month":
      return 60 * 60 * 24 * 30;
  }
};

export default WorkflowEmails;
