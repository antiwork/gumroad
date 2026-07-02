# frozen_string_literal: true

class Checkout::ReturnsController < ApplicationController
  include ClientConfirmedOrderFinalization

  layout "inertia"

  before_action :set_noindex_header

  def show
    ActiveRecord::Base.connection.stick_to_primary!

    order = Order.find_by_secure_external_id(params[:id], scope: "confirm")
    e404 unless order

    charge = order.charges.find { _1.stripe_payment_intent_id.present? }
    e404 unless charge && ActiveSupport::SecurityUtils.secure_compare(charge.stripe_payment_intent_id, params[:payment_intent].to_s)

    responses, charge_intent = finalize_client_confirmed_order(order)
    results = responses.values

    if results.any? && results.all? { _1[:success] && !_1[:processing] }
      redirect_to success_redirect_url(order), allow_other_host: true
    elsif results.any? { _1[:processing] } || charge_intent&.succeeded?
      set_meta_tag(title: "Processing your payment")
      render inertia: "Checkout/Returns/Pending"
    else
      restore_cart(order)
      flash[:alert] = failure_message(responses)
      redirect_to checkout_path
    end
  end

  private
    def restore_cart(order)
      cart = Cart.find_by(order:)
      return if cart.nil? || cart.alive?
      return if Cart.fetch_by(user: cart.user, browser_guid: cart.browser_guid).present?

      cart.mark_undeleted!
    end

    def success_redirect_url(order)
      purchases = order.purchases.select(&:successful?)
      purchase = purchases.first
      return checkout_path if purchase.nil?

      if purchases.one? && purchase.has_content?
        if purchase.link.native_type == Link::NATIVE_TYPE_COFFEE
          "#{purchase.url_redirect.download_page_url}?purchase_email=#{CGI.escape(purchase.email)}"
        else
          "#{purchase.url_redirect.download_page_url}?receipt=true"
        end
      elsif logged_in_user&.confirmed? && purchases.all?(&:has_content?)
        library_url(purchase_id: purchases.map(&:external_id))
      else
        purchase.link.long_url
      end
    end

    def failure_message(responses)
      responses.values.filter_map { _1[:error_message] }.first || "Sorry, something went wrong."
    end
end
