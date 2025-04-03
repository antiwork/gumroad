# frozen_string_literal: true

class Product::VariantsUpdaterService
  attr_reader :product, :skus_params
  attr_accessor :variants_params

  delegate :price_currency_type,
           :skus_enabled,
           :variant_categories_alive,
           :skus, to: :product

  def initialize(product:, variants_params:, skus_params: {})
    @product = product
    @variants_params = variants_params
    @skus_params = skus_params.values
  end

  def perform
    self.variants_params = clean_variants_params(variants_params)

    existing_categories = variant_categories_alive.to_a
    keep_categories = []

    variants_params.each do |category|
      variant_category_updater = Product::VariantCategoryUpdaterService.new(
        product:,
        category_params: category
      )
      variant_category = variant_category_updater.perform
      keep_categories << variant_category if category[:id].present?
    end

    categories_to_delete = existing_categories - keep_categories
    categories_to_delete.each do |variant_category|
      variant_category.mark_deleted! unless variant_category.has_alive_grouping_variants_with_purchases?
    end

    begin
      Product::SkusUpdaterService.new(product:, skus_params:).perform if skus_enabled
    rescue ActiveRecord::RecordInvalid => e
      product.errors.add(:base, e.message)
      raise e
    end
  end

  private
    def clean_variants_params(params)
      return [] if !params.present?

      variant_array = params.is_a?(Hash) ? params.values : params
      variant_array.map do |variant|
        # TODO: product_edit_react cleanup
        options = variant[:options].is_a?(Hash) ? variant[:options].values : variant[:options]
        {
          title: variant[:name],
          id: variant[:id],
          options: options&.map do |option|
            new_option = option.slice(:id, :temp_id, :name, :description, :url, :customizable_price, :recurrence_price_values, :max_purchase_count, :integrations, :rich_content, :apply_price_changes_to_existing_memberships, :subscription_price_change_effective_date, :subscription_price_change_message, :duration_in_minutes)

            # TODO: :product_edit_react cleanup
            if option[:price_difference_cents].present?
              option[:price] = option[:price_difference_cents]
              option[:price] /= 100.0 unless @product.single_unit_currency?
            end

            new_option.merge!(price_difference: option[:price])
            if price_change_settings = option.dig(:settings, :apply_price_changes_to_existing_memberships)
              if price_change_settings[:enabled] == "1"
                new_option[:apply_price_changes_to_existing_memberships] = true
                new_option[:subscription_price_change_effective_date] = price_change_settings[:effective_date]
                new_option[:subscription_price_change_message] = price_change_settings[:custom_message]
              else
                new_option[:apply_price_changes_to_existing_memberships] = false
                new_option[:subscription_price_change_effective_date] = nil
                new_option[:subscription_price_change_message] = nil
              end
            end
            if price_change_settings.blank? && !option[:apply_price_changes_to_existing_memberships]
              new_option[:subscription_price_change_effective_date] = nil
              new_option[:subscription_price_change_message] = nil
            end
            new_option
          end
        }
      end
    end
end
