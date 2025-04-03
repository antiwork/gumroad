# frozen_string_literal: true

class PurchaseCustomFieldsController < ApplicationController
  def create
    purchase = Purchase.find_by_external_id!(permitted_params.require(:purchase_id))
    custom_field = purchase.link.custom_fields.is_post_purchase.where(type: CustomField::FIELD_TYPE_TO_NODE_TYPE_MAPPING.keys).find_by_external_id!(permitted_params.require(:custom_field_id))

    purchase_custom_field = purchase.purchase_custom_fields.find_by(custom_field_id: custom_field.id)
    if purchase_custom_field.blank?
      purchase_custom_field = PurchaseCustomField.build_from_custom_field(custom_field:, value: permitted_params[:value])
      purchase.purchase_custom_fields << purchase_custom_field
    end

    purchase_custom_field.value = permitted_params[:value]

    if custom_field.type == CustomField::TYPE_FILE
      purchase_custom_field.files.attach(permitted_params[:file_signed_ids])
    end

    purchase_custom_field.save!

    head :no_content
  end

  private
    def permitted_params
      params.permit(:purchase_id, :custom_field_id, :value, file_signed_ids: [])
    end
end
