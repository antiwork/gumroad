# frozen_string_literal: true

class Api::Mobile::S3UtilityController < Api::Mobile::BaseController
  include CdnUrlHelper

  before_action { doorkeeper_authorize! :mobile_api }
  before_action :authorize_creator!

  def cdn_url_for_blob
    blob = ActiveStorage::Blob.find_by_key(params[:key])
    return render(json: { success: false, message: "Blob not found" }, status: :not_found) if blob.nil?
    render json: { url: cdn_url_for(blob.url) }
  end

  private
    def pundit_user
      @_pundit_user ||= SellerContext.new(user: current_api_user, seller: current_api_user)
    end

    def authorize_creator!
      authorize Installment, :create?
    rescue Pundit::NotAuthorizedError
      render json: { success: false, message: "This account can't read uploaded blobs." }, status: :forbidden
    end
end
