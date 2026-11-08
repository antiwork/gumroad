# frozen_string_literal: true

# The shared receipt for one seller's multi-item charge. Opens only for the buyer: through the tokened
# link mailed to the buyer's address, or signed in as the charge's purchaser. The sale notification
# links the same page without the token.
class ChargesController < ApplicationController
  skip_before_action :set_analytics_meta_tags, only: :receipt
  before_action :set_charge
  before_action :hide_layouts
  before_action :set_noindex_header

  def receipt
    unless buyer_verified?
      set_meta_tag(title: "View your receipt")
      set_analytics_meta_tags(seller: @charge.seller)
      return render :verify_buyer
    end

    message = CustomerMailer.receipt(nil, @charge.id, for_email: false)
    Premailer::Rails::Hook.perform(message)

    render html: message.html_part.body.raw_source.html_safe, layout: false
  end

  # Mails the buyer their receipt again; its shared receipt link is what proves the mailbox.
  def resend_receipt
    @charge.successful_purchases.first.resend_receipt
    redirect_to receipt_charge_path(@charge.external_id), notice: "Receipt sent to the email used for this order."
  rescue *REDIS_TRANSPORT_ERRORS => e
    ErrorNotifier.notify(e, charge_id: @charge.id)
    redirect_to receipt_charge_path(@charge.external_id), alert: "Sorry, something went wrong. Please try again."
  end

  private
    def set_charge
      @charge = Charge.find_by_external_id(params[:id])
      e404 unless @charge&.shared_receipt_eligible?
    end

    def buyer_verified?
      return true if Charge.find_by_secure_external_id(params[:token], scope: Charge::SHARED_RECEIPT_SCOPE) == @charge
      return false if logged_in_user.nil?

      logged_in_user.is_team_member? || @charge.successful_purchases.all? { _1.purchaser == logged_in_user }
    end
end
