# frozen_string_literal: true

class Checkout::Upsells::PausesController < Sellers::BaseController
  before_action :set_upsell!

  after_action :verify_authorized

  def create
    authorize [:checkout, @upsell], :pause?

    @upsell.update!(paused: true)

    head :no_content
  end

  def destroy
    authorize [:checkout, @upsell], :unpause?

    @upsell.update!(paused: false)

    head :no_content
  end

  private
    def set_upsell!
      @upsell = current_seller.upsells.alive.find_by_external_id!(params[:upsell_id])
    end
end
