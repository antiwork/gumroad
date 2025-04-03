# frozen_string_literal: true

class S3UtilityController < Sellers::BaseController
  include CdnUrlHelper

  before_action :authorize

  def generate_multipart_signature
    # Prevent attackers from using newlines to split the request body and bypass the seller check
    params["to_sign"].split(/[\n\r\s]/).grep(/\A\//).each do |url|
      return render(json: { success: false, error: "Unauthorized" }, status: :forbidden) if !%r{\A/#{S3_BUCKET}/\w+/#{current_seller.external_id}/}.match?(url)
    end

    render inline: Utilities.sign_with_aws_secret_key(params[:to_sign])
  end

  def current_utc_time_string
    render plain: Time.current.httpdate
  end

  def cdn_url_for_blob
    blob = ActiveStorage::Blob.find_by_key(params[:key])
    blob || e404
    respond_to do |format|
      format.html { redirect_to cdn_url_for(blob.url), allow_other_host: true }
      format.json { render json: { url: cdn_url_for(blob.url) } }
    end
  end

  private
    def authorize
      super(:s3_utility)
    end
end
