# frozen_string_literal: true

class CommissionsController < ApplicationController
  include ActiveStorage::SetCurrent

  def direct_upload
    commission = Commission.find_by_external_id!(params[:id])
    authorize commission, :update?
    ensure_files_can_be_changed!(commission)

    blob = ActiveStorage::Blob.create_before_direct_upload!(**blob_args, service_name: Commission::FILES_SERVICE)
    render json: blob.as_json(root: false, methods: :signed_id).merge(
      direct_upload: { url: blob.service_url_for_direct_upload, headers: blob.service_headers_for_direct_upload }
    )
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def update
    commission = Commission.find_by_external_id!(params[:id])
    authorize commission
    ensure_files_can_be_changed!(commission)

    file_signed_ids = permitted_params[:file_signed_ids]

    # Files already on the commission keep their service; anything new must have been reserved
    # through `direct_upload`, otherwise it would sit in the public bucket.
    kept_signed_ids = commission.files.map(&:signed_id)
    new_blobs = (file_signed_ids - kept_signed_ids).map { ActiveStorage::Blob.find_signed(_1) }
    if new_blobs.any? { _1.nil? || _1.service_name != Commission::FILES_SERVICE.to_s }
      return render json: { errors: ["One of the files was not uploaded correctly. Please try again."] }, status: :unprocessable_entity
    end

    commission.files.each do |file|
      file.purge unless file_signed_ids.delete(file.signed_id)
    end
    commission.files.attach(file_signed_ids)

    head :no_content
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def complete
    commission = Commission.find_by_external_id!(params[:id])
    authorize commission

    begin
      commission.create_completion_purchase!
    rescue ActiveRecord::RecordInvalid => e
      errors = e.record&.errors&.full_messages.presence || ["Failed to complete commission"]
      return render json: { errors: }, status: :unprocessable_entity
    rescue => e
      Rails.logger.error("Commission #{params[:id]} completion failed: #{e.class}: #{e.message}")
      return render json: { errors: ["Failed to complete commission"] }, status: :unprocessable_entity
    end

    head :no_content
  end

  private
    def ensure_files_can_be_changed!(commission)
      return if commission.files_are_editable?

      commission.errors.add(:base, "This commission has already been completed, so its files can no longer be changed.")
      raise ActiveRecord::RecordInvalid, commission
    end

    def blob_args
      params.expect(blob: [:filename, :byte_size, :checksum, :content_type]).to_h.symbolize_keys
    end

    def permitted_params
      params.permit(file_signed_ids: [])
    end
end
