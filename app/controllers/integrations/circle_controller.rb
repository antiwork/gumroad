# frozen_string_literal: true

class Integrations::CircleController < Sellers::BaseController
  before_action :skip_authorization

  def communities
    return render json: { success: false } if params[:api_key].blank?

    communities_response = CircleApi.new(params[:api_key]).get_communities
    return render json: { success: false } if !communities_response.success? || !communities_response.parsed_response.kind_of?(Array)

    render json: { success: true, communities: communities_response.parsed_response.map { |c| c.slice("name", "id") } }
  end

  def space_groups
    return render json: { success: false } if params[:community_id].blank? || params[:api_key].blank?

    space_groups_response = CircleApi.new(params[:api_key]).get_space_groups(params[:community_id])
    return render json: { success: false } if !space_groups_response.success? || !space_groups_response.parsed_response.kind_of?(Array)

    render json: { success: true, space_groups: space_groups_response.parsed_response.map { |c| c.slice("name", "id") } }
  end

  def communities_and_space_groups
    return render json: { success: false } if params[:community_id].blank? || params[:api_key].blank?

    communities_response = CircleApi.new(params[:api_key]).get_communities
    space_groups_response = CircleApi.new(params[:api_key]).get_space_groups(params[:community_id])
    return render json: { success: false } if !space_groups_response.success? || !space_groups_response.parsed_response.kind_of?(Array) ||
                                              !communities_response.success? || !communities_response.parsed_response.kind_of?(Array)

    render json: {
      success: true,
      communities: communities_response.parsed_response.map { |c| c.slice("name", "id") },
      space_groups: space_groups_response.parsed_response.map { |c| c.slice("name", "id") }
    }
  end
end
