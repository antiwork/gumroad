import { DirectUpload } from "@rails/activestorage";
import * as React from "react";
import { cast, createCast } from "ts-safe-cast";

import {
  CancellationRebuttalOption,
  SellerDisputeEvidence,
  submitForm,
  DisputeReason,
  disputeReasons,
  ReasonForWinningOption,
  reasonForWinningOptions,
  cancellationRebuttalOptions,
} from "$app/data/purchase/dispute_evidence_data";
import FileUtils from "$app/utils/file";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Button, NavigationButton } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { showAlert } from "$app/components/server-components/Alert";
import { useUserAgentInfo } from "$app/components/UserAgent";

const ALLOWED_EXTENSIONS = ["jpeg", "jpg", "png", "pdf"];

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
};

type Blobs = {
  receipt_image: Blob | null;
  policy_image: Blob | null;
  customer_communication_file: Blob | null;
};

type Blob = {
  byte_size: number;
  filename: string;
  key: string;
  signed_id: string | null;
  title: string;
};

const DisputeEvidencePage = ({ dispute_evidence, disputable, products }: Props) => {
  const reasonForWinningUID = React.useId();
  const cancellationRebuttalUID = React.useId();
  const refundRefusalExplanationUID = React.useId();
  const fileInputRef = React.useRef<HTMLInputElement>(null);
  const userAgentInfo = useUserAgentInfo();
  const purchaseDate = new Date(dispute_evidence.purchased_at).toLocaleString(userAgentInfo.locale, {
    dateStyle: "medium",
  });

  const [sellerDisputeEvidence, setSellerDisputeEvidence] = React.useState<SellerDisputeEvidence>({
    reasonForWinning: "",
    reasonForWinningOption: null,
    cancellationRebuttal: "",
    cancellationRebuttalOption: null,
    refundRefusalExplanation: "",
    customerCommunicationFileSignedBlobId: null,
  });

  const isReasonForWinningProvided =
    sellerDisputeEvidence.reasonForWinningOption === "other" && sellerDisputeEvidence.reasonForWinning === ""
      ? false
      : sellerDisputeEvidence.reasonForWinningOption != null;

  const isCancellationRebuttalProvided =
    sellerDisputeEvidence.cancellationRebuttalOption === "other" && sellerDisputeEvidence.cancellationRebuttal === ""
      ? false
      : sellerDisputeEvidence.cancellationRebuttalOption != null;

  const isInfoProvided =
    isReasonForWinningProvided ||
    isCancellationRebuttalProvided ||
    sellerDisputeEvidence.customerCommunicationFileSignedBlobId !== null ||
    sellerDisputeEvidence.refundRefusalExplanation !== "";

  const updateSellerDisputeEvidence = (update: Partial<SellerDisputeEvidence>) =>
    setSellerDisputeEvidence((prevSellerDisputeEvidence) => ({ ...prevSellerDisputeEvidence, ...update }));

  const [isSubmitting, setIsSubmitting] = React.useState(false);
  const [formSubmitted, setFormSubmitted] = React.useState(false);
  const handleSubmit = asyncVoid(async () => {
    try {
      setIsSubmitting(true);
      await submitForm(disputable.purchase_for_dispute_evidence_id, sellerDisputeEvidence);
      setFormSubmitted(true);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsSubmitting(false);
  });

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
        updateSellerDisputeEvidence({ customerCommunicationFileSignedBlobId: blob.signed_id });
        dispute_evidence.blobs.customer_communication_file = {
          byte_size: blob.byte_size,
          filename: blob.filename,
          key: blob.key,
          signed_id: blob.signed_id,
          title: "Customer communication",
        };
      }
      setIsUploading(false);
      if (fileInputRef.current) fileInputRef.current.value = "";
    });
  };

  const TEXTAREA_MAX_LENGTH = 3000;
  const TEXTAREA_ROWS = 7;
  const disputeReason = disputeReasons[dispute_evidence.dispute_reason];

  return (
    <div className="stack">
      <header>
        Dispute evidence
        <h2>Submit additional information</h2>
      </header>
      {formSubmitted ? (
        <div>Thank you!</div>
      ) : (
        <>
          <div>
            {products.length > 1 ? (
              <div>
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
              <p>
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
            <div role="alert" className="warning">
              You only have one opportunity to submit your response. We immediately forward your response and all
              supporting files to our payment processor. You can't edit the response or submit additional information,
              so make sure you've assembled all of your evidence before you submit.
            </div>
          </div>
          <div>
            <fieldset>
              <legend>
                <label htmlFor={reasonForWinningUID}>Why should you win this dispute?</label>
              </legend>
              {disputeReason.reasonsForWinning.map((option) => (
                <label key={option}>
                  <input
                    type="radio"
                    name="reasonForWinning"
                    value={option}
                    onChange={(evt) =>
                      updateSellerDisputeEvidence({
                        reasonForWinningOption: cast<ReasonForWinningOption>(evt.target.value),
                      })
                    }
                  />
                  {reasonForWinningOptions[option]}
                </label>
              ))}
              {sellerDisputeEvidence.reasonForWinningOption === "other" ? (
                <textarea
                  id={reasonForWinningUID}
                  maxLength={TEXTAREA_MAX_LENGTH}
                  rows={TEXTAREA_ROWS}
                  value={sellerDisputeEvidence.reasonForWinning}
                  onChange={(evt) => updateSellerDisputeEvidence({ reasonForWinning: evt.target.value })}
                />
              ) : null}
            </fieldset>
          </div>
          {disputable.is_subscription && dispute_evidence.dispute_reason === "subscription_canceled" ? (
            <div>
              <fieldset>
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
                        updateSellerDisputeEvidence({
                          cancellationRebuttalOption: cast<CancellationRebuttalOption>(evt.target.value),
                        })
                      }
                    />

                    {message}
                  </label>
                ))}
                {sellerDisputeEvidence.cancellationRebuttalOption === "other" ? (
                  <textarea
                    id={cancellationRebuttalUID}
                    maxLength={TEXTAREA_MAX_LENGTH}
                    rows={TEXTAREA_ROWS}
                    value={sellerDisputeEvidence.cancellationRebuttal}
                    onChange={(evt) => updateSellerDisputeEvidence({ cancellationRebuttal: evt.target.value })}
                  />
                ) : null}
              </fieldset>
            </div>
          ) : null}
          {"refusalRequiresExplanation" in disputeReason ? (
            <div>
              <fieldset>
                <legend>
                  <label htmlFor={refundRefusalExplanationUID}>Why is the customer not entitled to a refund?</label>
                </legend>
                <textarea
                  id={refundRefusalExplanationUID}
                  maxLength={TEXTAREA_MAX_LENGTH}
                  rows={TEXTAREA_ROWS}
                  value={sellerDisputeEvidence.refundRefusalExplanation}
                  onChange={(evt) => updateSellerDisputeEvidence({ refundRefusalExplanation: evt.target.value })}
                />
              </fieldset>
            </div>
          ) : null}
          <div>
            <fieldset>
              <legend>
                <label>Do you have additional evidence you'd like to provide?</label>
              </legend>

              <Files
                blobs={dispute_evidence.blobs}
                updateSellerDisputeEvidence={updateSellerDisputeEvidence}
                isSubmitting={isSubmitting}
              />

              {dispute_evidence.blobs.customer_communication_file === null ? (
                <>
                  <input
                    ref={fileInputRef}
                    type="file"
                    accept={ALLOWED_EXTENSIONS.map((ext) => `.${ext}`).join(",")}
                    tabIndex={-1}
                    onChange={handleFileUpload}
                  />
                  <Button outline disabled={isUploading || isSubmitting} onClick={() => fileInputRef.current?.click()}>
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
          </div>
          <div>
            <Button color="primary" disabled={!isInfoProvided || isSubmitting} onClick={handleSubmit}>
              {isSubmitting ? (
                <>
                  <LoadingSpinner /> Submitting...
                </>
              ) : (
                "Submit"
              )}
            </Button>
          </div>
        </>
      )}
    </div>
  );
};

const Files = ({
  blobs,
  updateSellerDisputeEvidence,
  isSubmitting,
}: {
  blobs: Blobs;
  updateSellerDisputeEvidence: ({
    customerCommunicationFileSignedBlobId,
  }: {
    customerCommunicationFileSignedBlobId: null;
  }) => void;
  isSubmitting: boolean;
}) => {
  const eligibleBlobs = Object.values(blobs).filter((b) => b !== null);
  if (eligibleBlobs.length < 1) return;

  const [isRemovingFile, setIsRemovingFile] = React.useState(false);
  const handleFileRemove = () => {
    setIsRemovingFile(true);
    updateSellerDisputeEvidence({ customerCommunicationFileSignedBlobId: null });
    blobs.customer_communication_file = null;
    setIsRemovingFile(false);
  };

  return (
    <div className="rows" role="list">
      {eligibleBlobs.map((blob) => (
        <div role="listitem" key={blob.key}>
          <div className="content">
            <Icon name="solid-document-text" className="type-icon" />
            <div>
              <h4>{blob.title}</h4>
              <ul className="inline">
                <li>{FileUtils.getFileExtension(blob.filename).toUpperCase()}</li>
                <li>{FileUtils.getFullFileSizeString(blob.byte_size)}</li>
              </ul>
            </div>
          </div>
          <div className="actions">
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
          </div>
        </div>
      ))}
    </div>
  );
};

export default register({ component: DisputeEvidencePage, propParser: createCast() });
