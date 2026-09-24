# frozen_string_literal: true

class PurchaseCustomFieldsController < ApplicationController
  def create
    purchase = Purchase.find_by_external_id!(permitted_params.require(:purchase_id))

    # The download page is the only surface that renders these fields, and it always loads one
    # purchase through that purchase's own URL redirect — a purchase external id alone must not be
    # enough to write. Token binding only; the page already gates entitlement.
    return head :not_found unless buyer_can_write?(purchase)

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
    def buyer_can_write?(purchase)
      token = permitted_params[:token]
      token.is_a?(String) && token.present? && UrlRedirect.exists?(token:, purchase_id: purchase.id)
    end

    def permitted_params
      params.permit(:purchase_id, :custom_field_id, :value, :token, file_signed_ids: [])
    end
end
