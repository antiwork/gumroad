# frozen_string_literal: true

# Sends nothing outbound: "execute" only reports where the draft Installment lives.
class Marketing::Channels::Email
  class Unavailable < StandardError; end

  Result = Struct.new(:action, :intent_url, :connect_path, :edit_url, keyword_init: true)

  def initialize(action, **_options)
    @action = action
  end

  def call
    product = action.link
    seller = action.user
    # Match draft creation's product lock, then serialize against cancellation.
    product.with_lock do
      action.with_lock do
        unless product.published? && product.user_id == action.user_id && !action.cancelled?
          raise Unavailable, "This launch email is no longer available."
        end

        Result.new(action:, intent_url: nil, connect_path: nil, edit_url: edit_url(product, seller))
      end
    end
  end

  private
    attr_reader :action

    def edit_url(product, seller)
      installment = Marketing::LaunchEmail.new(product:, seller:, utm_link: action.utm_link).installment
      return if installment.nil?

      Rails.application.routes.url_helpers.edit_email_path(installment.external_id)
    end
end
