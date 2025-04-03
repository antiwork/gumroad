# frozen_string_literal: true

class Api::V2::UsersController < Api::V2::BaseController
  before_action -> { doorkeeper_authorize!(*Doorkeeper.configuration.public_scopes.concat([:view_public])) }, only: [:show, :ifttt_sale_trigger]

  def show
    if params[:is_ifttt]
      user = current_resource_owner
      user.name = current_resource_owner.email if user.name.blank?
      return success_with_object(:data, user)
    end

    success_with_object(:user, current_resource_owner)
  end

  def ifttt_status
    render json: { status: "success" }
  end

  def ifttt_sale_trigger
    limit = params[:limit] || 50

    sales = if params[:after].present?
      current_resource_owner.sales.successful_or_preorder_authorization_successful.where(
        "created_at >= ?", Time.zone.at(params[:after].to_i)
      ).order("created_at ASC").limit(limit)
    elsif params[:before].present?
      current_resource_owner.sales.successful_or_preorder_authorization_successful.where(
        "created_at <= ?", Time.zone.at(params[:before].to_i)
      ).order("created_at DESC").limit(limit)
    else
      current_resource_owner.sales.successful_or_preorder_authorization_successful.order("created_at DESC").limit(limit)
    end

    sales = sales.map(&:as_json_for_ifttt)

    success_with_object(:data, sales)
  end
end
