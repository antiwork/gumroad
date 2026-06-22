# frozen_string_literal: true

class ProfileSectionsController < ApplicationController
  before_action :authorize

  def create
    section = save_service.create!(permitted_params)
    render json: { id: section.external_id }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  rescue ActiveRecord::SubclassNotFound
    render json: { error: "Invalid section type" }, status: :unprocessable_entity
  end

  def update
    section = current_seller.seller_profile_sections.find_by_external_id!(params[:id])
    save_service.update!(section, permitted_params)
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  def destroy
    current_seller.seller_profile_sections.find_by_external_id!(params[:id]).destroy!
  end

  private
    def save_service
      SellerProfileSections::SaveService.new(seller: current_seller)
    end

    def authorize
      super(section_policy)
    end

    def section_policy
      [:profile_section]
    end

    def permitted_params
      params.permit(policy(section_policy).public_send("permitted_attributes_for_#{action_name}"))
    end
end
