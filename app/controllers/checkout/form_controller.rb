# frozen_string_literal: true

class Checkout::FormController < Sellers::BaseController
  layout "inertia", only: [:show]

  def show
    authorize [:checkout, :form]

    @title = "Checkout form"
    form_props = Checkout::FormPresenter.new(pundit_user:).form_props

    render inertia: "Checkout/Form/Show",
           props: form_props
  end

  def update
    authorize [:checkout, :form]
    begin
      ActiveRecord::Base.transaction do
        current_seller.update!(permitted_params[:user]) if permitted_params[:user]
        if permitted_params[:custom_fields]
          all_fields = current_seller.custom_fields.to_a
          permitted_params[:custom_fields].each do |field|
            existing = all_fields.extract! { _1.external_id == field[:id] }[0] || current_seller.custom_fields.build
            existing.update!(field.except(:id, :products))
            existing.products = field[:global] ? [] : current_seller.products.by_external_ids(field[:products])
          end
          all_fields.each(&:destroy)
          current_seller.custom_fields.reload
        end
      end
      render json: Checkout::FormPresenter.new(pundit_user:).form_props
    rescue ActiveRecord::RecordInvalid => e
      render json: { error_message: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  end

  private
    def permitted_params
      params.permit(policy([:checkout, :form]).permitted_attributes)
    end
end
