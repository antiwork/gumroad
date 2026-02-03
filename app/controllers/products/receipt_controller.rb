# frozen_string_literal: true

class Products::ReceiptController < Products::BaseController
  def edit
    render inertia: "Products/Receipt/Edit", props: Products::Edit::ReceiptTabPresenter.new(product: @product, pundit_user:).props
  end

  def update
    if params[:unpublish].present? && @product.published?
      @product.unpublish!
      check_offer_codes_validity
      return redirect_back fallback_location: edit_product_receipt_path(@product.unique_permalink), notice: "Unpublished!", status: :see_other
    end

    begin
      ActiveRecord::Base.transaction do
        update_receipt_attributes
      end
    rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid => e
      error_message = @product.errors.full_messages.first || e.message
      return redirect_to edit_product_receipt_path(@product.unique_permalink), alert: error_message, status: :see_other
    end

    check_offer_codes_validity

    redirect_to edit_product_receipt_path(@product.unique_permalink), notice: "Changes saved!", status: :see_other
  end

  private

    def update_receipt_attributes
      @product.assign_attributes(product_permitted_params.except(:custom_domain))
      @product.save!
    end

    def product_permitted_params
      params.require(:product).permit(policy(@product).receipt_tab_permitted_attributes)
    end
end
