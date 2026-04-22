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

    sales = current_resource_owner.sales
      .successful_or_preorder_authorization_successful
      .includes(:link, :purchaser)

    sales = if params[:after].present?
      sales.where("created_at >= ?", Time.zone.at(params[:after].to_i))
           .order("created_at ASC").limit(limit)
    elsif params[:before].present?
      sales.where("created_at <= ?", Time.zone.at(params[:before].to_i))
           .order("created_at DESC").limit(limit)
    else
      sales.order("created_at DESC").limit(limit)
    end

    sales = sales.map(&:as_json_for_ifttt)

    success_with_object(:data, sales)
  end
end
