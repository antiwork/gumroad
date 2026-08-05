import { FileDetail, Paperclip, Trash } from "@boxicons/react";
import { useForm, usePage } from "@inertiajs/react";
import { DirectUpload } from "@rails/activestorage";
import * as React from "react";
import typia from "typia";

import {
  CancellationRebuttalOption,
  DisputeReason,
  disputeReasons,
  ReasonForWinningOption,
  reasonForWinningOptions,
  cancellationRebuttalOptions,
  cancellationRebuttalOptionKeys,
} from "$app/data/purchase/dispute_evidence_data";
import FileUtils from "$app/utils/file";

import { Button, NavigationButton } from "$app/components/Button";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Card, CardContent } from "$app/components/ui/Card";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { InlineList } from "$app/components/ui/InlineList";
import { Label } from "$app/components/ui/Label";
import { Radio } from "$app/components/ui/Radio";
import { Row, RowActions, RowContent, Rows } from "$app/components/ui/Rows";
import { Textarea } from "$app/components/ui/Textarea";
import { useUserAgentInfo } from "$app/components/UserAgent";

const ALLOWED_EXTENSIONS = ["jpeg", "jpg", "png", "pdf"];

type Props = {
  dispute_evidence: {
    dispute_reason: DisputeReason;
    customer_email: string;
    purchased_at: string;
    duration_left_to_submit_evidence_formatted: string;
    seller_response_due_at: string | null;
    customer_communication_file_max_size: number;
    customer_communication_files_max_count: number;
    blobs: Blobs;
    saved: {
      reason_for_winning: string | null;
      cancellation_rebuttal: string | null;
      refund_refusal_explanation: string | null;
    };
  };
  disputable: {
    purchase_for_dispute_evidence_id: string;
    formatted_display_price: string;
    is_subscription: boolean;
  };
  products: {
    url: string;
    name: string;
  }[];
};

type Blobs = {
  receipt_image: BlobType | null;
  policy_image: BlobType | null;
  customer_communication_file: BlobType | null;
};

type BlobType = {
  byte_size: number;
  filename: string;
  key: string;
  signed_id: string | null;
  title: string;
};

type UploadedFile = {
  byte_size: number;
  filename: string;
  key: string;
  signed_id: string;
};

type FormData = {
  dispute_evidence: {
    reason_for_winning: string;
    cancellation_rebuttal: string;
    refund_refusal_explanation: string;
    customer_communication_file_signed_blob_ids: string[];
  };
};

// We store the display text of the chosen radio, not the option key, so restoring a saved answer
// means matching that text back against the options this dispute reason offers. Anything that does
// not match was typed into "Other", which is also where an option retired since the seller answered
// lands — a stored string with no live radio still has to be editable.
const restoreChoice = <T extends string>(
  savedText: string | null,
  options: Record<string, string>,
  available: readonly T[],
): { option: T | "other" | null; text: string } => {
  if (savedText === null || savedText === "") return { option: null, text: "" };
  const matched = available.find((option) => options[option] === savedText);
  return matched !== undefined && matched !== "other"
    ? { option: matched, text: "" }
    : { option: "other", text: savedText };
};

export default function Show() {
  const { dispute_evidence, disputable, products } = typia.assert<Props>(usePage().props);

  const reasonForWinningUID = React.useId();
  const cancellationRebuttalUID = React.useId();
  const refundRefusalExplanationUID = React.useId();
  const fileInputRef = React.useRef<HTMLInputElement>(null);
  const userAgentInfo = useUserAgentInfo();
  const saved = dispute_evidence.saved;
  const savedReasonForWinning = restoreChoice(
    saved.reason_for_winning,
    reasonForWinningOptions,
    disputeReasons[dispute_evidence.dispute_reason].reasonsForWinning,
  );
  const savedCancellationRebuttal = restoreChoice(
    saved.cancellation_rebuttal,
    cancellationRebuttalOptions,
    cancellationRebuttalOptionKeys,
  );
  const [reasonForWinningOption, setReasonForWinningOption] = React.useState<ReasonForWinningOption | null>(
    savedReasonForWinning.option,
  );
  const [cancellationRebuttalOption, setCancellationRebuttalOption] = React.useState<CancellationRebuttalOption | null>(
    savedCancellationRebuttal.option,
  );
  const blobs = dispute_evidence.blobs;
  const [isUploading, setIsUploading] = React.useState(false);
  const [uploadedFiles, setUploadedFiles] = React.useState<UploadedFile[]>([]);
  const [isConfirming, setIsConfirming] = React.useState(false);
  const hasSavedResponse =
    savedReasonForWinning.option !== null ||
    savedCancellationRebuttal.option !== null ||
    (saved.refund_refusal_explanation ?? "") !== "";

  const form = useForm<FormData>({
    dispute_evidence: {
      reason_for_winning: savedReasonForWinning.text,
      cancellation_rebuttal: savedCancellationRebuttal.text,
      refund_refusal_explanation: saved.refund_refusal_explanation ?? "",
      customer_communication_file_signed_blob_ids: [],
    },
  });

  const purchaseDate = new Date(dispute_evidence.purchased_at).toLocaleString(userAgentInfo.locale, {
    dateStyle: "medium",
  });
  const sellerResponseDueAt =
    dispute_evidence.seller_response_due_at !== null
      ? new Date(dispute_evidence.seller_response_due_at).toLocaleString(userAgentInfo.locale, {
          dateStyle: "medium",
          timeStyle: "short",
        })
      : null;

  const updateFormData = (update: Partial<FormData["dispute_evidence"]>) => {
    form.setData("dispute_evidence", { ...form.data.dispute_evidence, ...update });
  };

  const isReasonForWinningProvided =
    reasonForWinningOption === "other" && form.data.dispute_evidence.reason_for_winning === ""
      ? false
      : reasonForWinningOption != null;

  const isCancellationRebuttalProvided =
    cancellationRebuttalOption === "other" && form.data.dispute_evidence.cancellation_rebuttal === ""
      ? false
      : cancellationRebuttalOption != null;

  const isInfoProvided =
    isReasonForWinningProvided ||
    isCancellationRebuttalProvided ||
    uploadedFiles.length > 0 ||
    form.data.dispute_evidence.refund_refusal_explanation !== "";

  const submitDisputeEvidence = () => {
    // The submission is one-shot, so a click that beats the last upload would spend it on a
    // partial packet. The buttons are already disabled while uploading; this is the backstop.
    if (isUploading) return;
    setIsConfirming(false);
    const reasonForWinningText =
      reasonForWinningOption === "other"
        ? form.data.dispute_evidence.reason_for_winning
        : reasonForWinningOption !== null
          ? reasonForWinningOptions[reasonForWinningOption]
          : "";

    const cancellationRebuttalText =
      cancellationRebuttalOption === "other"
        ? form.data.dispute_evidence.cancellation_rebuttal
        : cancellationRebuttalOption !== null
          ? cancellationRebuttalOptions[cancellationRebuttalOption]
          : "";

    form.transform((data) => ({
      dispute_evidence: {
        reason_for_winning: reasonForWinningText,
        cancellation_rebuttal: cancellationRebuttalText,
        refund_refusal_explanation: data.dispute_evidence.refund_refusal_explanation,
        // Read off the upload list rather than form data: an upload finishing while the seller
        // types would otherwise write back a stale copy of the whole dispute_evidence object
        // and silently revert their text.
        customer_communication_file_signed_blob_ids: uploadedFiles.map(({ signed_id }) => signed_id),
      },
    }));
    form.put(Routes.purchase_dispute_evidence_path(disputable.purchase_for_dispute_evidence_id));
  };

  const maxFileCount = dispute_evidence.customer_communication_files_max_count;
  // A prior save's attachment counts against the server's max: the update action folds it into
  // the merge inputs before enforcing the limit, so ignoring it here would let the seller pick a
  // selection the server is guaranteed to reject.
  const savedFileCount = blobs.customer_communication_file !== null ? 1 : 0;
  const remainingFileSlots = maxFileCount - savedFileCount - uploadedFiles.length;

  // Uploads run sequentially so the order the seller picked becomes the page order of the
  // merged PDF: for a chat log, order is part of the evidence.
  const handleFileUpload = async () => {
    const selectedFiles = Array.from(fileInputRef.current?.files ?? []);
    if (fileInputRef.current) fileInputRef.current.value = "";
    if (selectedFiles.length === 0) return;

    if (selectedFiles.length > remainingFileSlots)
      return showAlert(
        remainingFileSlots === maxFileCount
          ? `You can attach up to ${maxFileCount} files.`
          : `You can attach ${remainingFileSlots} more ${remainingFileSlots === 1 ? "file" : "files"}.`,
        "error",
      );
    if (selectedFiles.some((file) => !FileUtils.isFileNameExtensionAllowed(file.name, ALLOWED_EXTENSIONS)))
      return showAlert("Invalid file type.", "error");
    if (selectedFiles.some((file) => file.size > dispute_evidence.customer_communication_file_max_size))
      return showAlert("The file exceeds the maximum size allowed.", "error");

    setIsUploading(true);
    for (const file of selectedFiles) {
      try {
        const blob = await new Promise<UploadedFile>((resolve, reject) => {
          new DirectUpload(file, Routes.rails_direct_uploads_path()).create((error, uploaded) => {
            if (error) reject(error);
            else
              resolve({
                byte_size: uploaded.byte_size,
                filename: uploaded.filename,
                key: uploaded.key,
                signed_id: uploaded.signed_id,
              });
          });
        });
        setUploadedFiles((prev) => [...prev, blob]);
      } catch (error) {
        showAlert(
          `${file.name} could not be uploaded${error instanceof Error ? `: ${error.message}` : ""}. Any remaining files were not uploaded.`,
          "error",
        );
        break;
      }
    }
    setIsUploading(false);
  };

  const removeEvidenceFile = (key: string) => {
    setUploadedFiles((prev) => prev.filter((file) => file.key !== key));
  };

  const TEXTAREA_MAX_LENGTH = 3000;
  const TEXTAREA_ROWS = 7;
  const disputeReason = disputeReasons[dispute_evidence.dispute_reason];

  return (
    <Card className="mx-auto my-8 max-w-2xl">
      <CardContent asChild>
        <header>
          Dispute evidence
          <h2 className="grow">Submit additional information</h2>
        </header>
      </CardContent>
      <CardContent>
        {products.length > 1 ? (
          <div className="grow">
            <p>
              A customer of yours ({dispute_evidence.customer_email}) has disputed their purchase made on {purchaseDate}{" "}
              of the following {products.length} items for {disputable.formatted_display_price}.
            </p>
            <br />
            <ul>
              {products.map((product) => (
                <li key={product.name}>
                  <a href={product.url} target="_blank" rel="noreferrer">
                    {product.name}
                  </a>
                </li>
              ))}
            </ul>
          </div>
        ) : (
          <p className="grow">
            A customer of yours ({dispute_evidence.customer_email}) has disputed their purchase made on {purchaseDate}{" "}
            of{" "}
            <a href={products[0]?.url} target="_blank" rel="noreferrer">
              {products[0]?.name}
            </a>{" "}
            for {disputable.formatted_display_price}.
          </p>
        )}
        <p>
          <strong>{disputeReason.message}</strong>
        </p>
        <p>
          <strong>
            {sellerResponseDueAt !== null
              ? `Any additional information you can provide by ${sellerResponseDueAt} (${dispute_evidence.duration_left_to_submit_evidence_formatted} left) will help us win on your behalf.`
              : `Any additional information you can provide in the next ${dispute_evidence.duration_left_to_submit_evidence_formatted} will help us win on your behalf.`}
          </strong>
        </p>
        <Alert variant="warning">
          <strong>You can keep adding to this until the deadline.</strong> Our payment processor accepts one submission
          per dispute, so we hold your response and send it at the deadline. Come back any time before then to add files
          or revise what you wrote — after the deadline nothing more can be added, not even by contacting support.
        </Alert>
        {hasSavedResponse ? (
          <Alert variant="info">
            <strong>Your saved response is filled in below.</strong> Change whatever you want and save again — saving
            replaces the fields you fill in and leaves the rest as they are.
          </Alert>
        ) : null}
      </CardContent>
      <CardContent>
        <Fieldset className="grow basis-0">
          <FieldsetTitle>
            <Label htmlFor={reasonForWinningUID}>Why should you win this dispute?</Label>
          </FieldsetTitle>
          {disputeReason.reasonsForWinning.map((option) => (
            <Label key={option}>
              <Radio
                name="reasonForWinning"
                value={option}
                checked={reasonForWinningOption === option}
                onChange={(evt) => setReasonForWinningOption(typia.assert<ReasonForWinningOption>(evt.target.value))}
              />
              {reasonForWinningOptions[option]}
            </Label>
          ))}
          {reasonForWinningOption === "other" ? (
            <Textarea
              id={reasonForWinningUID}
              maxLength={TEXTAREA_MAX_LENGTH}
              rows={TEXTAREA_ROWS}
              value={form.data.dispute_evidence.reason_for_winning}
              onChange={(evt) => updateFormData({ reason_for_winning: evt.target.value })}
            />
          ) : null}
        </Fieldset>
      </CardContent>
      {disputable.is_subscription && dispute_evidence.dispute_reason === "subscription_canceled" ? (
        <CardContent>
          <Fieldset className="grow basis-0">
            <FieldsetTitle>
              <Label htmlFor={cancellationRebuttalUID}>Why was the customer's subscription not canceled?</Label>
            </FieldsetTitle>
            {Object.entries(cancellationRebuttalOptions).map(([option, message]) => (
              <Label key={option}>
                <Radio
                  name="cancellationRebuttal"
                  value={option}
                  checked={cancellationRebuttalOption === option}
                  onChange={(evt) =>
                    setCancellationRebuttalOption(typia.assert<CancellationRebuttalOption>(evt.target.value))
                  }
                />
                {message}
              </Label>
            ))}
            {cancellationRebuttalOption === "other" ? (
              <Textarea
                id={cancellationRebuttalUID}
                maxLength={TEXTAREA_MAX_LENGTH}
                rows={TEXTAREA_ROWS}
                value={form.data.dispute_evidence.cancellation_rebuttal}
                onChange={(evt) => updateFormData({ cancellation_rebuttal: evt.target.value })}
              />
            ) : null}
          </Fieldset>
        </CardContent>
      ) : null}
      {"refusalRequiresExplanation" in disputeReason ? (
        <CardContent>
          <Fieldset className="grow basis-0">
            <FieldsetTitle>
              <Label htmlFor={refundRefusalExplanationUID}>Why is the customer not entitled to a refund?</Label>
            </FieldsetTitle>
            <Textarea
              id={refundRefusalExplanationUID}
              maxLength={TEXTAREA_MAX_LENGTH}
              rows={TEXTAREA_ROWS}
              value={form.data.dispute_evidence.refund_refusal_explanation}
              onChange={(evt) => updateFormData({ refund_refusal_explanation: evt.target.value })}
            />
          </Fieldset>
        </CardContent>
      ) : null}
      <CardContent>
        <Fieldset className="grow basis-0">
          <FieldsetTitle>
            <Label>Do you have additional evidence you'd like to provide?</Label>
          </FieldsetTitle>

          <Files
            blobs={blobs}
            uploadedFiles={uploadedFiles}
            onRemoveFile={removeEvidenceFile}
            isSubmitting={form.processing}
          />

          {remainingFileSlots > 0 ? (
            <>
              <input
                ref={fileInputRef}
                type="file"
                multiple
                accept={ALLOWED_EXTENSIONS.map((ext) => `.${ext}`).join(",")}
                className="sr-only"
                tabIndex={-1}
                onChange={() => void handleFileUpload()}
              />
              <Button outline disabled={isUploading || form.processing} onClick={() => fileInputRef.current?.click()}>
                {isUploading ? (
                  <>
                    <LoadingSpinner /> Uploading...
                  </>
                ) : (
                  <>
                    <Paperclip className="size-5" /> Upload customer communication
                  </>
                )}
              </Button>
              <p>
                Any communication with the customer that you feel is relevant to your case (emails, chats, etc. proving
                that they received the product or service, or screenshots demonstrating their use of or satisfaction
                with the product or service). You can attach up to {maxFileCount} JPG, PNG, or PDF files, each under{" "}
                {FileUtils.getReadableFileSize(dispute_evidence.customer_communication_file_max_size)}. We combine them
                into a single PDF in the order shown, so pick them in the order you want them read.
              </p>
            </>
          ) : null}
        </Fieldset>
      </CardContent>
      <CardContent>
        <Button
          color="primary"
          disabled={!isInfoProvided || isUploading || form.processing}
          onClick={() => setIsConfirming(true)}
          className="grow basis-0"
        >
          {form.processing ? (
            <>
              <LoadingSpinner /> Saving...
            </>
          ) : (
            "Save response"
          )}
        </Button>
      </CardContent>
      <Modal
        open={isConfirming}
        title="Save your response?"
        onClose={() => setIsConfirming(false)}
        footer={
          <>
            <Button onClick={() => setIsConfirming(false)}>Cancel</Button>
            <Button color="primary" disabled={isUploading || form.processing} onClick={submitDisputeEvidence}>
              Confirm and save
            </Button>
          </>
        }
      >
        <p>
          We send this to our payment processor at the deadline, not now, so you can come back and add to it until then.
        </p>
        {uploadedFiles.length > 0 ? (
          <p>
            You are attaching {uploadedFiles.length} {uploadedFiles.length === 1 ? "file" : "files"}
            {savedFileCount > 0 ? ", in addition to the file you already saved" : ""}.
          </p>
        ) : savedFileCount > 0 ? (
          <p>Your previously saved file stays attached. You can add more here any time before the deadline.</p>
        ) : (
          <p>You have not attached any files. You can add them here any time before the deadline.</p>
        )}
      </Modal>
    </Card>
  );
}

const Files = ({
  blobs,
  uploadedFiles,
  onRemoveFile,
  isSubmitting,
}: {
  blobs: Blobs;
  uploadedFiles: UploadedFile[];
  onRemoveFile: (key: string) => void;
  isSubmitting: boolean;
}) => {
  const evidenceBlobs = Object.values(blobs).filter((b): b is BlobType => b !== null);
  if (evidenceBlobs.length < 1 && uploadedFiles.length < 1) return null;

  return (
    <Rows role="list">
      {evidenceBlobs.map((blob) => (
        <Row role="listitem" key={blob.key}>
          <RowContent>
            <FileDetail pack="filled" className="type-icon size-5" />
            <div>
              <h4>{blob.title}</h4>
              <InlineList>
                <li>{FileUtils.getFileExtension(blob.filename).toUpperCase()}</li>
                <li>{FileUtils.getFullFileSizeString(blob.byte_size)}</li>
              </InlineList>
            </div>
          </RowContent>
          <RowActions>
            <NavigationButton outline href={Routes.s3_utility_cdn_url_for_blob_path({ key: blob.key })} target="_blank">
              View
            </NavigationButton>
          </RowActions>
        </Row>
      ))}
      {/* Numbered because the position shown is the page order of the merged PDF we send. */}
      {uploadedFiles.map((file, index) => (
        <Row role="listitem" key={file.key}>
          <RowContent>
            <FileDetail pack="filled" className="type-icon size-5" />
            <div>
              <h4>
                {index + 1}. {file.filename}
              </h4>
              <InlineList>
                <li>{FileUtils.getFileExtension(file.filename).toUpperCase()}</li>
                <li>{FileUtils.getFullFileSizeString(file.byte_size)}</li>
              </InlineList>
            </div>
          </RowContent>
          <RowActions>
            <NavigationButton outline href={Routes.s3_utility_cdn_url_for_blob_path({ key: file.key })} target="_blank">
              View
            </NavigationButton>
            <Button
              size="icon"
              color="danger"
              outline
              aria-label="Remove"
              disabled={isSubmitting}
              onClick={() => onRemoveFile(file.key)}
            >
              <Trash className="size-5" />
            </Button>
          </RowActions>
        </Row>
      ))}
    </Rows>
  );
};

Show.publicLayout = true;
