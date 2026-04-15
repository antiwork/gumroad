# frozen_string_literal: true

class Purchases::DisputeEvidenceController < ApplicationController
  layout "inertia"

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
    signed_blob_id = dispute_evidence_params[:customer_communication_file_signed_blob_id]
    @dispute_evidence.assign_attributes(
      dispute_evidence_params.slice(:cancellation_rebuttal, :reason_for_winning, :refund_refusal_explanation)
    )

    if signed_blob_id.present?
      blob = covert_and_optimize_blob_if_needed(signed_blob_id)
      @dispute_evidence.customer_communication_file.attach(blob)
    end
    @dispute_evidence.update_as_seller_submitted!

    FightDisputeJob.perform_async(@dispute_evidence.dispute.id)
    redirect_to success_purchase_dispute_evidence_path(@purchase.external_id), status: :see_other
  rescue ActiveRecord::RecordInvalid
    redirect_to purchase_dispute_evidence_path(@purchase.external_id), alert: @dispute_evidence.errors.full_messages.to_sentence
  end

  private
    def dispute_evidence_params
      params.require(:dispute_evidence).permit(
        :reason_for_winning,
        :cancellation_rebuttal,
        :refund_refusal_explanation,
        :customer_communication_file_signed_blob_id
      )
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
    def covert_and_optimize_blob_if_needed(signed_blob_id)
      blob = ActiveStorage::Blob.find_signed(signed_blob_id)
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
