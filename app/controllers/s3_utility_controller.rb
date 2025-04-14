# frozen_string_literal: true

class S3UtilityController < ApplicationController
  include CdnUrlHelper

  before_action :authenticate_user!
  after_action :verify_authorized

  def generate_multipart_signature
    to_sign = params[:to_sign] || ""
    authorize external_ids_to_sign(to_sign), policy_class: S3UtilityPolicy

    render inline: Utilities.sign_with_aws_secret_key(to_sign)
  rescue Pundit::NotAuthorizedError
    head :forbidden
  end

  def current_utc_time_string
    authorize :s3_utility

    render plain: Time.current.httpdate
  end

  def cdn_url_for_blob
    authorize :s3_utility

    blob = ActiveStorage::Blob.find_by!(key: params[:key])

    respond_to do |format|
      format.html { redirect_to cdn_url_for(blob.url), allow_other_host: true }
      format.json { render json: { url: cdn_url_for(blob.url) } }
    end
  end

  private
    def external_ids_to_sign(to_sign)
      ids = to_sign
        # Prevent attackers from using newlines to split the request body and
        # bypass the seller check
        .split
        .grep(/\A\//)
        .map { |url| url[%r{\A/#{S3_BUCKET}/\w+/(\w+)/}o, 1] }

      { external_ids: ids }
    end
end
