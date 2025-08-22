# frozen_string_literal: true

class Checkout::DiscountCollectionsController < Sellers::BaseController
  include Pagy::Backend

  PER_PAGE = 10

  def index
    authorize [:checkout, DiscountCollection]

    @title = "Discount Collections"
    pagination, discount_collections = fetch_discount_collections
    @presenter = Checkout::DiscountCollectionsPresenter.new(pundit_user:, discount_collections:, pagination:)
  end

  def paged
    authorize [:checkout, DiscountCollection]

    pagination, discount_collections = fetch_discount_collections
    @presenter = Checkout::DiscountCollectionsPresenter.new(pundit_user:)

    render json: { discount_collections: discount_collections.map { @presenter.discount_collection_props(_1) }, pagination: }
  end

  def create
    authorize [:checkout, DiscountCollection]

    discount_collection = current_seller.discount_collections.build(discount_collection_params)

    if discount_collection.save
      pagination, discount_collections = fetch_discount_collections
      presenter = Checkout::DiscountCollectionsPresenter.new(pundit_user:)
      render json: { success: true, discount_collections: discount_collections.map { presenter.discount_collection_props(_1) }, pagination: }
    else
      render json: { success: false, error_message: discount_collection.errors.full_messages.first }
    end
  end

  def update
    discount_collection = DiscountCollection.find_by_external_id!(params[:id])
    authorize [:checkout, discount_collection]

    if discount_collection.update(discount_collection_params)
      pagination, discount_collections = fetch_discount_collections
      presenter = Checkout::DiscountCollectionsPresenter.new(pundit_user:)
      render json: { success: true, discount_collections: discount_collections.map { presenter.discount_collection_props(_1) }, pagination: }
    else
      render json: { success: false, error_message: discount_collection.errors.full_messages.first }
    end
  end

  def destroy
    discount_collection = DiscountCollection.find_by_external_id!(params[:id])
    authorize [:checkout, discount_collection]

    # Check if user wants to delete associated discount codes
    delete_codes = params[:delete_codes] == 'true'

    if delete_codes
      # Delete the collection and all associated offer codes
      ActiveRecord::Base.transaction do
        discount_collection.offer_codes.alive.each(&:mark_deleted!)
        discount_collection.mark_deleted(validate: false)
      end
    else
      # Just delete the collection (offer codes will be nullified due to dependent: :nullify)
      discount_collection.mark_deleted(validate: false)
    end

    if discount_collection.deleted?
      render json: { success: true }
    else
      render json: { success: false, error_message: discount_collection.errors.full_messages.first }
    end
  end

            def show
            discount_collection = DiscountCollection.find_by_external_id!(params[:id])
            authorize [:checkout, discount_collection]

            @title = discount_collection.name
            @presenter = Checkout::DiscountCollectionDetailPresenter.new(
              pundit_user:,
              discount_collection:,
              offer_codes: discount_collection.offer_codes.alive.includes(:purchases).order(created_at: :desc)
            )
          end

          def export_csv
            discount_collection = DiscountCollection.find_by_external_id!(params[:id])
            authorize [:checkout, discount_collection]

            csv_data = discount_collection.export_to_csv
            filename = "#{discount_collection.name.parameterize}-discount-codes-#{Date.current}.csv"

            send_data csv_data, filename: filename, type: 'text/csv'
          end

          def quick_create_code
            discount_collection = DiscountCollection.find_by_external_id!(params[:id])
            authorize [:checkout, discount_collection]

            unless discount_collection.has_defaults?
              render json: { success: false, error_message: "Collection must have default discount parameters set" }
              return
            end

            offer_code = discount_collection.generate_quick_code(params[:name])

            if offer_code.save
              render json: {
                success: true,
                message: "Quick code created successfully",
                offer_code: {
                  id: offer_code.external_id,
                  name: offer_code.name,
                  code: offer_code.code,
                  url: offer_code.code_url
                }
              }
            else
              render json: { success: false, error_message: offer_code.errors.full_messages.first }
            end
          end

          def bulk_create_codes
            discount_collection = DiscountCollection.find_by_external_id!(params[:id])
            authorize [:checkout, discount_collection]

            count = params[:count].to_i
            name_template = params[:name_template]
            discount_params = params[:discount]
            selected_product_ids = params[:selected_product_ids]
            universal = params[:universal]
            max_purchase_count = params[:max_purchase_count]
            valid_at = params[:valid_at]
            expires_at = params[:expires_at]
            minimum_quantity = params[:minimum_quantity]
            duration_in_billing_cycles = params[:duration_in_billing_cycles]
            minimum_amount_cents = params[:minimum_amount_cents]

            created_codes = []
            failed_codes = []

            count.times do |i|
              code_name = name_template.gsub('{n}', (i + 1).to_s)
              code_value = generate_unique_code(current_seller)

              offer_code = current_seller.offer_codes.build(
                name: code_name,
                code: code_value,
                discount_collection: discount_collection,
                products: universal ? [] : current_seller.products.by_external_ids(selected_product_ids),
                universal: universal,
                max_purchase_count: max_purchase_count,
                amount_percentage: discount_params[:type] == 'percent' ? discount_params[:value] : nil,
                amount_cents: discount_params[:type] == 'cents' ? discount_params[:value] : nil,
                valid_at: valid_at.present? ? Date.parse(valid_at) : nil,
                expires_at: expires_at.present? ? Date.parse(expires_at) : nil,
                minimum_quantity: minimum_quantity,
                duration_in_billing_cycles: duration_in_billing_cycles,
                minimum_amount_cents: minimum_amount_cents
              )

              if offer_code.save
                created_codes << offer_code
              else
                failed_codes << { name: code_name, error: offer_code.errors.full_messages.first }
              end
            end

            if failed_codes.empty?
              render json: {
                success: true,
                message: "Successfully created #{created_codes.count} discount codes",
                created_count: created_codes.count
              }
            else
              render json: {
                success: false,
                error_message: "Failed to create #{failed_codes.count} codes. #{failed_codes.first[:error]}",
                failed_codes: failed_codes
              }
            end
          end

            private
            def discount_collection_params
              params.permit(
                :name,
                :description,
                :default_discount_type,
                :default_discount_value,
                :default_max_purchase_count,
                :default_valid_at,
                :default_expires_at,
                :default_minimum_quantity,
                :default_duration_in_billing_cycles,
                :default_minimum_amount_cents
              ).merge(
                params[:discount_collection]&.permit(
                  :name,
                  :description,
                  :default_discount_type,
                  :default_discount_value,
                  :default_max_purchase_count,
                  :default_valid_at,
                  :default_expires_at,
                  :default_minimum_quantity,
                  :default_duration_in_billing_cycles,
                  :default_minimum_amount_cents
                ) || {}
              )
            end

    def paged_params
      params.permit(:page, sort: [:key, :direction])
    end

    def fetch_discount_collections
      scope = current_seller.discount_collections.alive.includes(:offer_codes).order(created_at: :desc)

      if paged_params[:sort].present?
        sort_key = paged_params[:sort][:key]
        sort_direction = paged_params[:sort][:direction]

        case sort_key
        when "name"
          scope = scope.order(name: sort_direction)
        when "created_at"
          scope = scope.order(created_at: sort_direction)
        when "offer_codes_count"
          scope = scope.left_joins(:offer_codes).group(:id).order("COUNT(offer_codes.id) #{sort_direction}")
        end
      end

      pagination, discount_collections = pagy(scope, items: PER_PAGE, page: paged_params[:page] || 1)
      [PagyPresenter.new(pagination).metadata, discount_collections]
    end

    def generate_unique_code(user)
      loop do
        code = SecureRandom.alphanumeric(8).upcase
        break code unless user.offer_codes.alive.exists?(code: code)
      end
    end
end
