# frozen_string_literal: true

class S3UtilityController < Sellers::BaseController
  include CdnUrlHelper

  UPLOAD_ROOT = "attachments"
  HTTP_DATE = /[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2} GMT/
  CONTENT_TYPE = /[ -~]*/
  KEY_CHARACTERS = /[!-~&&[^?#]]/
  UPLOAD_ID = /[\w.~+=-]+/
  # S3 numbers parts 1 to 10,000.
  PART_NUMBER = /10000|[1-9]\d{0,3}/

  before_action :authorize

  def generate_multipart_signature
    to_sign = params["to_sign"]
    return render(json: { success: false, error: "Missing required parameter: to_sign" }, status: :bad_request) if to_sign.blank?
    return render(json: { success: false, error: "Invalid parameter: to_sign" }, status: :bad_request) unless to_sign.is_a?(String)

    return render(json: { success: false, error: "Unauthorized" }, status: :forbidden) unless multipart_upload_request?(to_sign)

    render inline: Utilities.sign_with_aws_secret_key(to_sign)
  end

  def current_utc_time_string
    render plain: Time.current.httpdate
  end

  def cdn_url_for_blob
    key = params[:key]
    blob = key.is_a?(String) ? ActiveStorage::Blob.find_by_key(key) : nil
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

    # The secret signs whatever it is given, so only the requests Evaporate makes for a multipart
    # upload into the seller's own folder are signed: see makeStringToSign in vendor/assets/javascripts/evaporate.js.
    def multipart_upload_request?(to_sign)
      date = "x-amz-date:#{HTTP_DATE}"
      object = %r{/#{Regexp.escape(S3_BUCKET)}/#{UPLOAD_ROOT}/#{Regexp.escape(current_seller.external_id)}/(?<rest>#{KEY_CHARACTERS}+)}
      match = to_sign.match(/\APOST\n\n#{CONTENT_TYPE}\n\nx-amz-acl:private\n#{date}\n#{object}\?uploads\z/) ||
        to_sign.match(/\APUT\n\n#{CONTENT_TYPE}\n\n#{date}\n#{object}\?partNumber=#{PART_NUMBER}&uploadId=#{UPLOAD_ID}\z/) ||
        to_sign.match(%r{\APOST\n\napplication/xml; charset=UTF-8\n\n#{date}\n#{object}\?uploadId=#{UPLOAD_ID}\z})
      return false if match.nil?

      match[:rest].split("/", -1).none? { _1.empty? || _1 == "." || _1 == ".." }
    end
end
