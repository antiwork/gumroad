# frozen_string_literal: true

class CheckDefaultOfferCodesWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  # Check all products with default offer codes enabled and notify sellers
  # if their codes have expired or been exhausted
  def perform
    Link.where(default_offer_code_enabled: true)
        .where.not(default_offer_code_id: nil)
        .includes(:default_offer_code, :user)
        .find_each do |product|
      check_product(product)
    end
  end

  private

    def check_product(product)
      offer_code = product.default_offer_code
      return if offer_code.nil?

      if offer_code.inactive?
        notify_expired(product, offer_code)
        disable_default_discount(product)
      elsif !offer_code.is_valid_for_purchase?
        notify_exhausted(product, offer_code)
        disable_default_discount(product)
      end
    end

    def notify_expired(product, offer_code)
      CreatorMailer.default_discount_code_expired(
        product_id: product.id,
        offer_code_id: offer_code.id
      ).deliver_later
    end

    def notify_exhausted(product, offer_code)
      CreatorMailer.default_discount_code_exhausted(
        product_id: product.id,
        offer_code_id: offer_code.id
      ).deliver_later
    end

    def disable_default_discount(product)
      product.update!(default_offer_code_enabled: false)
    end
end
