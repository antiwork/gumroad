# frozen_string_literal: true

class S3UtilityController < ApplicationController
  include CdnUrlHelper

  before_action :authenticate_user!
  before_action -> { authorize :s3_utility }

  after_action :verify_authorized

  def generate_multipart_signature
    return head :forbidden unless authorized_to_sign?(params[:to_sign])

    render inline: Utilities.sign_with_aws_secret_key(params[:to_sign])
  end

  def current_utc_time_string
    render plain: Time.current.httpdate
  end

  def cdn_url_for_blob
    blob = ActiveStorage::Blob.find_by!(key: params[:key])

    respond_to do |format|
      format.html { redirect_to cdn_url_for(blob.url), allow_other_host: true }
      format.json { render json: { url: cdn_url_for(blob.url) } }
    end
  end

  private
    def authorized_to_sign?(to_sign)
      unauthorized_ids = external_ids_to_sign(to_sign) - external_ids_authorized_for_signing
      unauthorized_ids.empty?
    end

    def external_ids_to_sign(to_sign)
      to_sign
        # Prevent attackers from using newlines to split the request body and
        # bypass the seller check
        .split
        .grep(/\A\//)
        .map { |url| url[%r{\A/#{S3_BUCKET}/\w+/(\w+)/}o, 1] }
    end

    def external_ids_authorized_for_signing
      [
        logged_in_user.external_id,
        authorized_to_sign_for_current_seller? ? current_seller.external_id : nil
      ].compact
    end

    def authorized_to_sign_for_current_seller?
      logged_in_user.role_admin_for?(current_seller) || logged_in_user.role_marketing_for?(current_seller)
    end
end
