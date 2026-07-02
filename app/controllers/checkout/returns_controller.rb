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

    responses = finalize_client_confirmed_order(order)

    if responses.values.any? { _1[:processing] }
      set_meta_tag(title: "Processing your payment")
      render inertia: "Checkout/Returns/Pending"
    elsif responses.values.any? { _1[:success] }
      redirect_to success_redirect_url(order), allow_other_host: true
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
      if purchases.one? && purchase.has_content? && purchase.link.native_type != Link::NATIVE_TYPE_COFFEE
        "#{purchase.url_redirect.download_page_url}?receipt=true"
      else
        purchase.link.long_url
      end
    end

    def failure_message(responses)
      responses.values.filter_map { _1[:error_message] }.first || "Sorry, something went wrong."
    end
end
