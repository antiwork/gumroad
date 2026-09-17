# frozen_string_literal: true

# The email channel executes nothing outbound: the launch email is prepared as a draft
# Installment and the seller sends it from the Emails tab, so "execute" only reports
# where the draft lives. It keeps the same result shape as the X executor so the shared
# API can render either channel without a special case.
class Marketing::Channels::Email
  Result = Struct.new(:action, :intent_url, :connect_path, :edit_url, keyword_init: true)

  def initialize(action, **_options)
    @action = action
  end

  def call
    Result.new(action:, intent_url: nil, connect_path: nil, edit_url:)
  end

  private
    attr_reader :action

    def edit_url
      installment = Marketing::LaunchEmail.new(product: action.link, seller: action.user, utm_link: action.utm_link).installment
      return if installment.nil?

      Rails.application.routes.url_helpers.edit_email_path(installment.external_id)
    end
end
