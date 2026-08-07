# frozen_string_literal: true

class Purchases::DisputeEvidenceController < ApplicationController
  layout "inertia"

  SECURE_ID_SCOPE = "dispute_evidence"

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

  # The chargeback emails link with a token scoped to SECURE_ID_SCOPE, expiring with the
  # evidence window itself, so a stale or forwarded link stops working the moment the window
  # does. purchase.external_id is buyer-visible (library/download data), so it must never
  # resolve here on its own — only an authenticated seller-owner may fall back to it, which
  # covers already-delivered emails sent before this scope existed.

  def show
    set_meta_tag(title: "Submit additional information")
    set_noindex_header

    render inertia: "Purchases/DisputeEvidence/Show", props: DisputeEvidencePagePresenter.new(@dispute_evidence, purchase_route_id: @purchase_route_id).props
  end

  def success
    set_meta_tag(title: "Submit additional information")
    set_noindex_header

    render inertia: "Purchases/DisputeEvidence/Success",
           props: DisputeEvidencePagePresenter.new(@dispute_evidence, purchase_route_id: @purchase_route_id).success_props
  end

  def update
    input_blobs = customer_communication_file_blobs
    # A revision is additive per field: the form always posts all three text fields, so assigning
    # them wholesale would let a seller who returns to attach a file blank the statement they wrote
    # yesterday. But a field the seller explicitly cleared must still clear — only an ABSENT param
    # means "leave unchanged", so params.require raises before this, and slice+compact_blank on the
    # empty string would silently keep the old value the seller just deleted.
    @dispute_evidence.assign_attributes(
      dispute_evidence_params.slice(:cancellation_rebuttal, :reason_for_winning, :refund_refusal_explanation)
    )

    if input_blobs.one? && !@dispute_evidence.customer_communication_file.attached?
      attached_blob = covert_and_optimize_blob_if_needed(input_blobs.first)
      @dispute_evidence.customer_communication_file.attach(attached_blob)
    elsif input_blobs.any?
      # customer_communication_file is has_one_attached, so a bare #attach on a later save would
      # replace rather than add to what a prior save already sent — silently dropping the earlier
      # evidence for a seller who returns to add one more file. Fold the existing attachment into
      # the merge inputs first (read before .attach replaces it below) so nothing already saved is
      # lost. Stripe accepts a single file for this field, so multiple uploads are merged into one
      # PDF before attaching. The merge stays inline: FightDisputeJob can fire the moment the window
      # closes, and an async merge would let it forward the evidence before the merged file exists.
      existing_blob = @dispute_evidence.customer_communication_file.blob if @dispute_evidence.customer_communication_file.attached?
      merge_blobs = [existing_blob, *input_blobs].compact
      merged_blob = DisputeEvidence::MergeCustomerCommunicationFilesService.perform(
        blobs: merge_blobs,
        max_size: @dispute_evidence.customer_communication_file_max_size
      )
      @dispute_evidence.customer_communication_file.attach(merged_blob)
    end
    @dispute_evidence.update_as_seller_submitted!
    # Only once the submission is persisted: a validation failure below has to leave the
    # seller's uploads intact, since a retry re-sends the same signed ids.
    input_blobs.each(&:purge) if merged_blob

    # Nothing goes to Stripe here — FightDisputesJob forwards the latest version once the window
    # closes, which is what lets the seller keep revising. An already-elapsed window never reaches
    # this point: check_if_needs_redirect refuses the save, because a submission the job is already
    # forwarding cannot be added to.
    redirect_to success_purchase_dispute_evidence_path(@purchase_route_id), status: :see_other
  rescue ActiveRecord::RecordInvalid
    merged_blob&.purge
    redirect_to purchase_dispute_evidence_path(@purchase_route_id), alert: @dispute_evidence.errors.full_messages.to_sentence
  rescue DisputeEvidence::MergeCustomerCommunicationFilesService::MergeError => e
    redirect_to purchase_dispute_evidence_path(@purchase_route_id), alert: e.message
  end

  private
    def set_purchase
      requested_id = params[:purchase_id] || params[:id]
      @purchase = Purchase.find_by_secure_external_id(requested_id, scope: SECURE_ID_SCOPE)
      if @purchase
        @purchase_route_id = requested_id
      else
        @purchase = legacy_seller_purchase(requested_id)
        @purchase_route_id = @purchase&.external_id
      end
      @purchase || e404
    end

    # Pre-existing emails already delivered with the buyer-visible external_id keep working, but
    # only for the account that owns the sale — a signed-out or buyer request never reaches this.
    def legacy_seller_purchase(requested_id)
      return unless logged_in_user

      purchase = Purchase.find_by_external_id(requested_id)
      purchase if purchase && logged_in_user.role_owner_for?(purchase.seller)
    end

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
        elsif @dispute_evidence.resolved?
          "Additional information can no longer be submitted for this dispute."
        elsif !@dispute_evidence.accepting_evidence?
          # Window elapsed but the row is not resolved yet: FightDisputeJob is forwarding it, so
          # anything saved now would arrive too late to be part of the submission.
          "The deadline for submitting additional information for this dispute has passed."
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
