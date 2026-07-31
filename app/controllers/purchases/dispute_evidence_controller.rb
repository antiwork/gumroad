# frozen_string_literal: true

class Purchases::DisputeEvidenceController < ApplicationController
  layout "inertia"

  # Sellers reach this page from a one-off emailed link and have only 72 hours
  # (DisputeEvidence::SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS) to send us their
  # side of a chargeback before we forward whatever we have to the card network.
  # A suspension that lands inside that window is not a reason to throw the
  # evidence away: whether the seller keeps their account is a separate question
  # from whether this particular charge was legitimate, and losing the dispute
  # by default costs the buyer's bank fee and our win rate too. The generic
  # `check_suspended` filter blocks every non-GET request for a suspended user,
  # which silently turns the submit button into "You can't perform this action
  # because your account has been suspended" and drops their evidence, so we opt
  # this one action out. Nothing here grants account access: the page is scoped
  # to a single disputed purchase, and `check_if_needs_redirect` still enforces
  # the contacted/not-yet-submitted/not-resolved window.
  skip_before_action :check_suspended

  before_action :set_purchase, :set_dispute_evidence
  before_action :check_if_needs_redirect, except: [:success]

  def show
    set_meta_tag(title: "Submit additional information")
    set_noindex_header

    render inertia: "Purchases/DisputeEvidence/Show", props: DisputeEvidencePagePresenter.new(@dispute_evidence).props
  end

  def success
    set_meta_tag(title: "Submit additional information")
    set_noindex_header

    render inertia: "Purchases/DisputeEvidence/Success"
  end

  def update
    input_blobs = customer_communication_file_blobs
    @dispute_evidence.assign_attributes(
      dispute_evidence_params.slice(:cancellation_rebuttal, :reason_for_winning, :refund_refusal_explanation)
    )

    if input_blobs.one?
      attached_blob = covert_and_optimize_blob_if_needed(input_blobs.first)
      @dispute_evidence.customer_communication_file.attach(attached_blob)
    elsif input_blobs.many?
      # Stripe accepts a single file for this evidence field, so multiple uploads are merged
      # into one PDF before attaching. The merge stays inline: the submit below is one-shot,
      # and an async merge would let FightDisputeJob forward the evidence before the merged
      # file exists.
      merged_blob = DisputeEvidence::MergeCustomerCommunicationFilesService.perform(
        blobs: input_blobs,
        max_size: @dispute_evidence.customer_communication_file_max_size
      )
      @dispute_evidence.customer_communication_file.attach(merged_blob)
    end
    @dispute_evidence.update_as_seller_submitted!
    # Only once the submission is persisted: a validation failure below has to leave the
    # seller's uploads intact, since a retry re-sends the same signed ids.
    input_blobs.each(&:purge) if merged_blob

    FightDisputeJob.perform_async(@dispute_evidence.dispute.id)
    redirect_to success_purchase_dispute_evidence_path(@purchase.external_id), status: :see_other
  rescue ActiveRecord::RecordInvalid
    merged_blob&.purge
    redirect_to purchase_dispute_evidence_path(@purchase.external_id), alert: @dispute_evidence.errors.full_messages.to_sentence
  rescue DisputeEvidence::MergeCustomerCommunicationFilesService::MergeError => e
    redirect_to purchase_dispute_evidence_path(@purchase.external_id), alert: e.message
  end

  private
    def dispute_evidence_params
      params.require(:dispute_evidence).permit(
        :reason_for_winning,
        :cancellation_rebuttal,
        :refund_refusal_explanation,
        :customer_communication_file_signed_blob_id,
        customer_communication_file_signed_blob_ids: []
      )
    end

    # Asset bundles and server code don't deploy atomically, so a seller holding the old
    # JS bundle still submits the singular param. One file — from either param shape —
    # keeps today's direct-attach behaviour, including the PNG conversion below.
    def customer_communication_file_signed_blob_ids
      signed_blob_ids = Array.wrap(dispute_evidence_params[:customer_communication_file_signed_blob_ids]).compact_blank
      signed_blob_ids.presence || Array.wrap(dispute_evidence_params[:customer_communication_file_signed_blob_id].presence)
    end

    # A signed id that no longer resolves means the upload expired or the seller is retrying a
    # submission whose blobs were already consumed — an alert, not a 500.
    def customer_communication_file_blobs
      customer_communication_file_signed_blob_ids.map { ActiveStorage::Blob.find_signed!(_1) }
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
      raise DisputeEvidence::MergeCustomerCommunicationFilesService::MergeError,
            "We could not find your uploaded files. Please upload them again."
    end

    def set_dispute_evidence
      disputable = @purchase.charge.presence || @purchase
      @dispute_evidence = disputable.dispute.dispute_evidence
    end

    def check_if_needs_redirect
      message = \
        if @dispute_evidence.not_seller_contacted?
          # The feature flag was not enabled when the email was sent out
          "You are not allowed to perform this action."
        elsif @dispute_evidence.seller_submitted?
          "Additional information has already been submitted for this dispute."
        elsif @dispute_evidence.resolved?
          "Additional information can no longer be submitted for this dispute."
        end
      return if message.blank?

      redirect_to dashboard_url, alert: message
    end

    # Stripe rejects certain PNG images with the following error:
    # > We don't support uploading certain types of images. These unsupported images include PNG-format images that use
    # > 16-bit depth or interlacing. Please convert your image to PDF or JPEG and try again.
    # Rather than blocking the user from submitting PNGs, convert to JPG and optimize the file.
    #
    def covert_and_optimize_blob_if_needed(blob)
      return blob unless blob.content_type == "image/png"

      variant = blob.variant(convert: "jpg", quality: 80)
      new_blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(variant.processed.download),
        filename: "#{File.basename(blob.filename.to_s, File.extname(blob.filename.to_s))}.jpg",
        content_type: "image/jpeg"
      )
      blob.purge
      new_blob
    end
end
