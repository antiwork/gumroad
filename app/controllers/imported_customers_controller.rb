# frozen_string_literal: true

class ImportedCustomersController < ApplicationController
  PUBLIC_ACTIONS = %i[unsubscribe].freeze
  before_action :authenticate_user!, except: PUBLIC_ACTIONS
  after_action :verify_authorized, except: PUBLIC_ACTIONS

  def destroy
    imported_customer = current_seller.imported_customers.find_by_external_id(params[:id])
    authorize imported_customer

    if imported_customer.present?
      imported_customer.deleted_at = Time.current
      imported_customer.save!
      render json: { success: true, message: "Deleted!", imported_customer: }
    else
      render json: { success: false }
    end
  end

  def unsubscribe
    @imported_customer = ImportedCustomer.find_by_external_id(params[:id]) || e404
    @imported_customer.deleted_at = if @imported_customer.deleted_at
      nil
    else
      Time.current
    end
    @imported_customer.save!
  end

  def index
    authorize ImportedCustomer

    imported_customers = current_seller.imported_customers.alive.order("imported_customers.purchase_date DESC")
    if params[:link_id].present?
      products = Link.by_unique_permalinks(params[:link_id])
      imported_customers = imported_customers.where(link_id: products)
    end
    page = params[:page].to_i
    imported_customers = imported_customers.limit(CustomersController::CUSTOMERS_PER_PAGE).offset(page.to_i * CustomersController::CUSTOMERS_PER_PAGE)
    render json: {
      customers: imported_customers.as_json(pundit_user:),
      begin_loading_imported_customers: true
    }
  end
end
