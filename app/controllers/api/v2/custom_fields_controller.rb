# frozen_string_literal: true

class Api::V2::CustomFieldsController < Api::V2::BaseController
  before_action(only: [:index]) { doorkeeper_authorize!(*Doorkeeper.configuration.public_scopes.concat([:view_public])) }
  before_action(only: [:create, :update, :destroy]) { doorkeeper_authorize! :edit_products }
  before_action :fetch_product
  before_action :fetch_custom_fields
  before_action :fetch_custom_field, only: %i[update destroy]
  # no whitelist here because custom fields are weird

  def index
    success_with_object(:custom_fields, @custom_fields)
  end

  def create
    custom_field_name = params[:name].presence || params[:url].presence || params[:label].presence
    return error_with_creating_object(:custom_field) if custom_field_name.blank?

    new_custom_field = {
      name: custom_field_name,
      required: params[:required] == "true",
      type: params[:type] || "text"
    }
    field = @product.user.custom_fields.new(new_custom_field.merge({ products: [@product] }))
    if field.save
      success_with_custom_field(field)
    else
      error_with_creating_object(:custom_field)
    end
  end

  def update
    if params[:required].nil?
      # nothing to change, so we succeeded in changing nothing!
      success_with_custom_field(@custom_field)
    else
      @custom_field.update(required: params[:required] == "true")
      if @product.update(custom_fields: @custom_fields)
        success_with_custom_field(@custom_field)
      else
        error_with_custom_field(@custom_field)
      end
    end
  end

  def destroy
    if @custom_field.products.count > 1 ? @custom_field.products.delete(@product) : @custom_field.delete
      success_with_custom_field
    else
      error_with_object(:custom_fields, @custom_fields)
    end
  end

  private
    def fetch_custom_fields
      @custom_fields = @product.custom_fields
    end

    def fetch_custom_field
      @custom_field = @custom_fields.where(name: params[:id]).last
      error_with_custom_field if @custom_field.nil?
    end

    def success_with_custom_field(custom_field = nil)
      success_with_object(:custom_field, custom_field)
    end

    def error_with_custom_field(custom_field = nil)
      error_with_object(:custom_field, custom_field)
    end
end
