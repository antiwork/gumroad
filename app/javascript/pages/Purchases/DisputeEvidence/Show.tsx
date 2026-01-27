import { DirectUpload } from "@rails/activestorage";
import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import {
  CancellationRebuttalOption,
  DisputeReason,
  disputeReasons,
  ReasonForWinningOption,
  reasonForWinningOptions,
  cancellationRebuttalOptions,
} from "$app/data/purchase/dispute_evidence_data";
import FileUtils from "$app/utils/file";
import { useUserAgentInfo } from "$app/components/UserAgent";

import { Button, NavigationButton } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Card, CardContent } from "$app/components/ui/Card";
import { Row, RowActions, RowContent, Rows } from "$app/components/ui/Rows";

const ALLOWED_EXTENSIONS = ["jpeg", "jpg", "png", "pdf"];

type Blob = {
  byte_size: number;
  filename: string;
  key: string;
  signed_id: string | null;
  title: string;
};

type Blobs = {
  receipt_image: Blob | null;
  policy_image: Blob | null;
  customer_communication_file: Blob | null;
};

type Props = {
  dispute_evidence: {
    dispute_reason: DisputeReason;
    customer_email: string;
    purchased_at: string;
    duration_left_to_submit_evidence_formatted: string;
    customer_communication_file_max_size: number;
    blobs: Blobs;
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
  submitted?: boolean;
};

type FormData = {
  dispute_evidence: {
    reason_for_winning: string | null;
    cancellation_rebuttal: string | null;
    refund_refusal_explanation: string;
    customer_communication_file_signed_blob_id: string | null;
  };
};

export default function DisputeEvidenceShow() {
  const { dispute_evidence, disputable, products, submitted } = cast<Props>(usePage().props);

  const reasonForWinningUID = React.useId();
  const cancellationRebuttalUID = React.useId();
  const refundRefusalExplanationUID = React.useId();
  const fileInputRef = React.useRef<HTMLInputElement>(null);
  const userAgentInfo = useUserAgentInfo();
  const purchaseDate = new Date(dispute_evidence.purchased_at).toLocaleString(userAgentInfo.locale, {
    dateStyle: "medium",
  });

  const [reasonForWinningOption, setReasonForWinningOption] = React.useState<ReasonForWinningOption | null>(null);
  const [reasonForWinningText, setReasonForWinningText] = React.useState("");
  const [cancellationRebuttalOption, setCancellationRebuttalOption] =
    React.useState<CancellationRebuttalOption | null>(null);
  const [cancellationRebuttalText, setCancellationRebuttalText] = React.useState("");
  const [refundRefusalExplanation, setRefundRefusalExplanation] = React.useState("");
  const [customerCommunicationFileSignedBlobId, setCustomerCommunicationFileSignedBlobId] = React.useState<
    string | null
  >(null);
  const [blobs, setBlobs] = React.useState<Blobs>(dispute_evidence.blobs);

  const form = useForm<FormData>({
    dispute_evidence: {
      reason_for_winning: null,
      cancellation_rebuttal: null,
      refund_refusal_explanation: "",
      customer_communication_file_signed_blob_id: null,
    },
  });

  const isReasonForWinningProvided =
    reasonForWinningOption === "other" && reasonForWinningText === ""
      ? false
      : reasonForWinningOption !== null;

  const isCancellationRebuttalProvided =
    cancellationRebuttalOption === "other" && cancellationRebuttalText === ""
      ? false
      : cancellationRebuttalOption !== null;

  const isInfoProvided =
    isReasonForWinningProvided ||
    isCancellationRebuttalProvided ||
    customerCommunicationFileSignedBlobId !== null ||
    refundRefusalExplanation !== "";

  const handleSubmit = () => {
    const reasonForWinning =
      reasonForWinningOption === "other"
        ? reasonForWinningText
        : reasonForWinningOption !== null
          ? reasonForWinningOptions[reasonForWinningOption]
          : null;

    const cancellationRebuttal =
      cancellationRebuttalOption === "other"
        ? cancellationRebuttalText
        : cancellationRebuttalOption !== null
          ? cancellationRebuttalOptions[cancellationRebuttalOption]
          : null;

    form.transform(() => ({
      dispute_evidence: {
        reason_for_winning: reasonForWinning,
        cancellation_rebuttal: cancellationRebuttal,
        refund_refusal_explanation: refundRefusalExplanation,
        customer_communication_file_signed_blob_id: customerCommunicationFileSignedBlobId,
      },
    }));

    form.put(Routes.purchase_dispute_evidence_path(disputable.purchase_for_dispute_evidence_id));
  };

  const [isUploading, setIsUploading] = React.useState(false);
  const handleFileUpload = () => {
    const file = fileInputRef.current?.files?.[0];
    if (!file) return;

    if (!FileUtils.isFileNameExtensionAllowed(file.name, ALLOWED_EXTENSIONS))
      return showAlert("Invalid file type.", "error");
    if (file.size > dispute_evidence.customer_communication_file_max_size)
      return showAlert("The file exceeds the maximum size allowed.", "error");

    setIsUploading(true);
    const upload = new DirectUpload(file, Routes.rails_direct_uploads_path());
    upload.create((error, blob) => {
      if (error) {
        showAlert(error.message, "error");
      } else {
        setCustomerCommunicationFileSignedBlobId(blob.signed_id);
        setBlobs((prev) => ({
          ...prev,
          customer_communication_file: {
            byte_size: blob.byte_size,
            filename: blob.filename,
            key: blob.key,
            signed_id: blob.signed_id,
            title: "Customer communication",
          },
        }));
      }
      setIsUploading(false);
      if (fileInputRef.current) fileInputRef.current.value = "";
    });
  };

  const handleFileRemove = () => {
    setCustomerCommunicationFileSignedBlobId(null);
    setBlobs((prev) => ({ ...prev, customer_communication_file: null }));
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
      {submitted ? (
        <CardContent>Thank you!</CardContent>
      ) : (
        <>
          <CardContent>
            {products.length > 1 ? (
              <div className="grow">
                <p>
                  A customer of yours ({dispute_evidence.customer_email}) has disputed their purchase made on{" "}
                  {purchaseDate} of the following {products.length} items for {disputable.formatted_display_price}.
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
                A customer of yours ({dispute_evidence.customer_email}) has disputed their purchase made on{" "}
                {purchaseDate} of{" "}
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
                Any additional information you can provide in the next{" "}
                {dispute_evidence.duration_left_to_submit_evidence_formatted} will help us win on your behalf.
              </strong>
            </p>
            <Alert variant="warning">
              You only have one opportunity to submit your response. We immediately forward your response and all
              supporting files to our payment processor. You can't edit the response or submit additional information,
              so make sure you've assembled all of your evidence before you submit.
            </Alert>
          </CardContent>
          <CardContent>
            <fieldset className="grow basis-0">
              <legend>
                <label htmlFor={reasonForWinningUID}>Why should you win this dispute?</label>
              </legend>
              {disputeReason.reasonsForWinning.map((option) => (
                <label key={option}>
                  <input
                    type="radio"
                    name="reasonForWinning"
                    value={option}
                    onChange={(evt) => setReasonForWinningOption(cast<ReasonForWinningOption>(evt.target.value))}
                  />
                  {reasonForWinningOptions[option]}
                </label>
              ))}
              {reasonForWinningOption === "other" ? (
                <textarea
                  id={reasonForWinningUID}
                  maxLength={TEXTAREA_MAX_LENGTH}
                  rows={TEXTAREA_ROWS}
                  value={reasonForWinningText}
                  onChange={(evt) => setReasonForWinningText(evt.target.value)}
                />
              ) : null}
            </fieldset>
          </CardContent>
          {disputable.is_subscription && dispute_evidence.dispute_reason === "subscription_canceled" ? (
            <CardContent>
              <fieldset className="grow basis-0">
                <legend>
                  <label htmlFor={cancellationRebuttalUID}>Why was the customer's subscription not canceled?</label>
                </legend>
                {Object.entries(cancellationRebuttalOptions).map(([option, message]) => (
                  <label key={option}>
                    <input
                      type="radio"
                      name="cancellationRebuttal"
                      value={option}
                      onChange={(evt) =>
                        setCancellationRebuttalOption(cast<CancellationRebuttalOption>(evt.target.value))
                      }
                    />
                    {message}
                  </label>
                ))}
                {cancellationRebuttalOption === "other" ? (
                  <textarea
                    id={cancellationRebuttalUID}
                    maxLength={TEXTAREA_MAX_LENGTH}
                    rows={TEXTAREA_ROWS}
                    value={cancellationRebuttalText}
                    onChange={(evt) => setCancellationRebuttalText(evt.target.value)}
                  />
                ) : null}
              </fieldset>
            </CardContent>
          ) : null}
          {"refusalRequiresExplanation" in disputeReason ? (
            <CardContent>
              <fieldset className="grow basis-0">
                <legend>
                  <label htmlFor={refundRefusalExplanationUID}>Why is the customer not entitled to a refund?</label>
                </legend>
                <textarea
                  id={refundRefusalExplanationUID}
                  maxLength={TEXTAREA_MAX_LENGTH}
                  rows={TEXTAREA_ROWS}
                  value={refundRefusalExplanation}
                  onChange={(evt) => setRefundRefusalExplanation(evt.target.value)}
                />
              </fieldset>
            </CardContent>
          ) : null}
          <CardContent>
            <fieldset className="grow basis-0">
              <legend>
                <label>Do you have additional evidence you'd like to provide?</label>
              </legend>

              <Files blobs={blobs} onRemove={handleFileRemove} isSubmitting={form.processing} />

              {blobs.customer_communication_file === null ? (
                <>
                  <input
                    ref={fileInputRef}
                    type="file"
                    accept={ALLOWED_EXTENSIONS.map((ext) => `.${ext}`).join(",")}
                    tabIndex={-1}
                    onChange={handleFileUpload}
                  />
                  <Button outline disabled={isUploading || form.processing} onClick={() => fileInputRef.current?.click()}>
                    {isUploading ? (
                      <>
                        <LoadingSpinner /> Uploading...
                      </>
                    ) : (
                      <>
                        <Icon name="paperclip" /> Upload customer communication
                      </>
                    )}
                  </Button>
                  <p>
                    Any communication with the customer that you feel is relevant to your case (emails, chats, etc.
                    proving that they received the product or service, or screenshots demonstrating their use of or
                    satisfaction with the product or service). Please upload one JPG, PNG, or PDF file under{" "}
                    {FileUtils.getReadableFileSize(dispute_evidence.customer_communication_file_max_size)}. If you have
                    multiple files, consolidate them into a single PDF.
                  </p>
                </>
              ) : null}
            </fieldset>
          </CardContent>
          <CardContent>
            <Button
              color="primary"
              disabled={!isInfoProvided || form.processing}
              onClick={handleSubmit}
              className="grow basis-0"
            >
              {form.processing ? (
                <>
                  <LoadingSpinner /> Submitting...
                </>
              ) : (
                "Submit"
              )}
            </Button>
          </CardContent>
        </>
      )}
    </Card>
  );
}

const Files = ({
  blobs,
  onRemove,
  isSubmitting,
}: {
  blobs: Blobs;
  onRemove: () => void;
  isSubmitting: boolean;
}) => {
  const eligibleBlobs = Object.values(blobs).filter((b): b is Blob => b !== null);
  if (eligibleBlobs.length < 1) return null;

  const [isRemovingFile, setIsRemovingFile] = React.useState(false);
  const handleFileRemove = () => {
    setIsRemovingFile(true);
    onRemove();
    setIsRemovingFile(false);
  };

  return (
    <Rows role="list">
      {eligibleBlobs.map((blob) => (
        <Row role="listitem" key={blob.key}>
          <RowContent>
            <Icon name="solid-document-text" className="type-icon" />
            <div>
              <h4>{blob.title}</h4>
              <ul className="inline">
                <li>{FileUtils.getFileExtension(blob.filename).toUpperCase()}</li>
                <li>{FileUtils.getFullFileSizeString(blob.byte_size)}</li>
              </ul>
            </div>
          </RowContent>
          <RowActions>
            <NavigationButton outline href={Routes.s3_utility_cdn_url_for_blob_path({ key: blob.key })} target="_blank">
              View
            </NavigationButton>
            {blob.signed_id ? (
              <Button
                color="danger"
                outline
                aria-label="Remove"
                disabled={isRemovingFile || isSubmitting}
                onClick={handleFileRemove}
              >
                <Icon name="trash2" />
              </Button>
            ) : null}
          </RowActions>
        </Row>
      ))}
    </Rows>
  );
};
