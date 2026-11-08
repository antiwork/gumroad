# frozen_string_literal: true

# The shared receipt for one seller's multi-item charge. Opens only for the buyer: signed in as the
# charge's purchaser, or after entering the buyer's email. Never for a charge that is not shared-eligible.
class ChargesController < ApplicationController
  skip_before_action :set_analytics_meta_tags, only: %i[receipt confirm_receipt_email]
  before_action :set_charge
  before_action :hide_layouts

  def confirm_receipt_email
    set_meta_tag(title: "Confirm Email")
    set_analytics_meta_tags(seller: @charge.seller)
  end

  def receipt
    unless buyer_verified?
      flash[:alert] = "Wrong email. Please try again." if params[:email].present?
      return redirect_to confirm_receipt_email_charge_path(@charge.external_id)
    end

    message = CustomerMailer.receipt(nil, @charge.id, for_email: false)
    Premailer::Rails::Hook.perform(message)

    render html: message.html_part.body.raw_source.html_safe, layout: false
  end

  private
    def set_charge
      @charge = Charge.find_by_external_id(params[:id])
      e404 unless @charge&.shared_receipt_eligible?
    end

    def buyer_verified?
      return true if logged_in_user && @charge.successful_purchases.all? { _1.purchaser == logged_in_user }
      return true if logged_in_user&.is_team_member?

      params[:email].present? &&
        ActiveSupport::SecurityUtils.secure_compare(@charge.shared_receipt_email.to_s.strip.downcase, params[:email].to_s.strip.downcase)
    end
end
