# frozen_string_literal: true

class Oauth::Notion::AuthorizationsController < Oauth::AuthorizationsController
  before_action :retrieve_notion_bot_token, only: [:new]

  private
    def retrieve_notion_bot_token
      if params[:code].present?
        response = NotionApi.new.get_bot_token(code: params[:code], user: current_resource_owner)
        Rails.logger.info "Retrieved Notion Bot Token: #{response.body.inspect}" if Rails.env.development?
      end
    end
end
