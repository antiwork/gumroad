# frozen_string_literal: true

class MergeCartsService
  attr_reader :source_cart, :target_cart, :user, :browser_guid, :email

  def initialize(source_cart:, target_cart:, user: nil, browser_guid: nil)
    @source_cart = source_cart
    @target_cart = target_cart
    @user = user || @target_cart&.user.presence || @source_cart&.user.presence
    @browser_guid = browser_guid || @source_cart&.browser_guid
    @email = @target_cart&.email.presence || @source_cart&.email.presence || @user&.email
  end

  def process
    ActiveRecord::Base.transaction do
      if source_cart.nil? || source_cart.deleted?
        target_cart&.update!(user:, browser_guid:, email:)
      elsif target_cart.nil? || target_cart.deleted?
        source_cart&.update!(user:, browser_guid:, email:)
      elsif source_cart.id != target_cart.id
        source_cart_products = source_cart.alive_cart_products
        target_cart_products = target_cart.alive_cart_products
        if source_cart_products.empty? && target_cart_products.empty?
          source_cart.mark_deleted!
          target_cart.update!(user:, browser_guid:, email:)
        else
          target_cart_product_ids = target_cart_products.pluck(:product_id, :option_id)
          source_cart_products.each do |cart_product|
            next if target_cart_product_ids.include?([cart_product.product_id, cart_product.option_id])
            target_cart.cart_products << cart_product.dup
          end
          target_cart_discount_codes = target_cart.discount_codes.map { _1["code"] }
          source_cart.discount_codes.each do |discount_code|
            target_cart.discount_codes << discount_code unless target_cart_discount_codes.include?(discount_code["code"])
          end
          target_cart.return_url = source_cart.return_url if target_cart.return_url.blank?
          target_cart.reject_ppp_discount = true if source_cart.reject_ppp_discount?
          target_cart.user = user
          target_cart.browser_guid = browser_guid
          target_cart.email = email
          target_cart.save!
          source_cart.mark_deleted!
        end
      end
    end
  rescue => e
    Rails.logger.error("Failed to merge source cart (#{source_cart&.id}) with target cart (#{target_cart&.id}): #{e.full_message}")
    Bugsnag.notify(e)

    source_cart.mark_deleted! if source_cart.alive?
  end
end
