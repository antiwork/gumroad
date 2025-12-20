# frozen_string_literal: true

class Product::VariantCategoryUpdaterService
  include CurrencyHelper

  attr_reader :product, :category_params
  attr_accessor :variant_category

  delegate :price_currency_type,
           :is_tiered_membership,
           :product_files,
           :errors,
           :variant_categories, to: :product

  ALLOWED_ATTRIBUTES = %i[
    name
    description
    price_difference_cents
    max_purchase_count
    position_in_category
    customizable_price
    subscription_price_change_effective_date
    subscription_price_change_message
    duration_in_minutes
    apply_price_changes_to_existing_memberships
    variant_category
    product_files
  ].freeze

  def initialize(product:, category_params:)
    @product = product
    @category_params = category_params
  end

  def perform
    if category_params[:id].present?
      self.variant_category = variant_categories.find_by_external_id(category_params[:id])
      variant_category.update(title: category_params[:title])
    else
      self.variant_category = variant_categories.build(title: category_params[:title])
    end

    if category_params[:options].nil?
      variant_category.variants.map(&:mark_deleted)
      variant_category.mark_deleted! if variant_category.title.blank?
    else
      existing_variants = variant_category.variants.to_a
      keep_variants = []
      validate_variant_recurrences!(category_params[:options])
      category_params[:options].each_with_index do |option, index|
        begin
          variant = create_or_update_variant!(option[:id],
                                              name: option[:name],
                                              description: option[:description],
                                              duration_in_minutes: option[:duration_in_minutes],
                                              price_difference_cents: string_to_price_cents(
                                                price_currency_type.to_sym,
                                                option[:price_difference].to_s
                                              ),
                                              customizable_price: option[:customizable_price],
                                              max_purchase_count: option[:max_purchase_count],
                                              position_in_category: index,
                                              variant_category:,
                                              apply_price_changes_to_existing_memberships: !!option[:apply_price_changes_to_existing_memberships],
                                              subscription_price_change_effective_date: option[:subscription_price_change_effective_date],
                                              subscription_price_change_message: option[:subscription_price_change_message])
          save_integrations(variant, option)
          save_rich_content(variant, option)
          variant.product_files = ProductFile.find(variant.alive_rich_contents.flat_map { _1.embedded_product_file_ids_in_order }.uniq)
          save_recurring_prices!(variant, option) if is_tiered_membership && has_variant_recurrences?
        rescue ActiveRecord::RecordInvalid, Link::LinkInvalid, ArgumentError => e
          error_message = variant.present? ? variant.errors.full_messages.to_sentence : e.message
          errors.add(:base, error_message)
          raise Link::LinkInvalid
        end
        keep_variants << variant if option[:id]
      end

      variants_to_delete = existing_variants - keep_variants
      variants_to_delete.map(&:mark_deleted) if variants_to_delete.present?
    end

    variant_category.save!
    variant_category
  end

  private
    def create_or_update_variant!(external_id, params)
      return Variant.create!(params.slice(*ALLOWED_ATTRIBUTES)) if external_id.blank?

      variant = product.variants.find_by_external_id!(external_id)
      variant.assign_attributes(params.slice(*ALLOWED_ATTRIBUTES))

      if variant.apply_price_changes_to_existing_memberships_changed? && !variant.apply_price_changes_to_existing_memberships?
        variant.subscription_plan_changes.for_product_price_change.alive.each(&:mark_deleted)
      end

      notify_members_of_price_change = variant.apply_price_changes_to_existing_memberships? && variant.subscription_price_change_effective_date_changed?
      variant.save!

      if notify_members_of_price_change
        ScheduleMembershipPriceUpdatesJob.perform_async(variant.id)
      elsif variant.flags_previously_changed? || variant.subscription_price_change_effective_date_previously_changed?
        Bugsnag.notify("Not notifying subscribers of membership price change - tier: #{variant.id}; apply_price_changes_to_existing_memberships: #{variant.apply_price_changes_to_existing_memberships?}; subscription_price_change_effective_date: #{variant.subscription_price_change_effective_date}")
      end

      variant
    end

    def has_variant_recurrences?
      @has_variant_recurrences ||= category_params[:options].map { |variant| variant[:recurrence_price_values] }.any?
    end

    def save_recurring_prices!(variant, option)
      if option[:recurrence_price_values].present?
        variant.save_recurring_prices!(option[:recurrence_price_values].to_h)
      end
    end

    def save_integrations(variant, option)
      enabled_integrations = []

      Integration::ALL_NAMES.each do |name|
        integration = product.find_integration_by_name(name)
        # TODO: :product_edit_react cleanup
        if (option.dig(:integrations, name) == "1" || option.dig(:integrations, name) == true) && integration.present?
          enabled_integrations << integration
        end
      end

      deleted_integrations = variant.active_integrations - enabled_integrations
      variant.live_base_variant_integrations.where(integration: deleted_integrations).map(&:mark_deleted!)
      variant.active_integrations << enabled_integrations - variant.active_integrations
    end

    def save_rich_content(variant, option)
      variant_rich_contents = option[:rich_content].is_a?(Array) ? option[:rich_content] : JSON.parse(option[:rich_content].presence || "[]", symbolize_names: true) || []
      rich_contents_to_keep = []
      existing_rich_contents = variant.alive_rich_contents.to_a
      variant_rich_contents.each.with_index do |variant_rich_content, index|
        rich_content = existing_rich_contents.find { |c| c.external_id == variant_rich_content[:id] } || variant.alive_rich_contents.build
        variant_rich_content[:description] = SaveContentUpsellsService.new(
          seller: variant.user,
          content: variant_rich_content[:description] || variant_rich_content[:content],
          old_content: rich_content.description || []
        ).from_rich_content
        rich_content.update!(title: variant_rich_content[:title].presence, description: variant_rich_content[:description].presence || [], position: index)
        rich_contents_to_keep << rich_content
      end
      (existing_rich_contents - rich_contents_to_keep).map(&:mark_deleted!)
    end

    # For tiered memberships that have per-tier pricing, validates that:
    # 1. Any tiers that have "pay-what-you-want" pricing enabled have
    # recurring price data and suggested prices are high enough
    # 2. All tiers must have pricing info for the product's default recurrence
    # 3. All tiers have the same set of recurrence options selected. (Currently
    # we do not allow, e.g., Tier 1 to have monthly & yearly plans and Tier 2
    # only to have yearly plans)
    def validate_variant_recurrences!(variants)
      return unless is_tiered_membership && has_variant_recurrences?

      variants.each_with_index do |variant, index|
        if variant[:customizable_price]
          # error if "pay what you want" enabled but missing recurrence_price_values
          if !variant[:recurrence_price_values].present?
            errors.add(:base, "Please provide suggested payment options.")
            raise Link::LinkInvalid, "Please provide suggested payment options."
          end

          # error if "pay what you want" enabled but suggested price is too low
          variant[:recurrence_price_values].each do |recurrence, price_info|
            if price_info[:suggested_price_cents].present? && (price_info[:price_cents].to_i > price_info[:suggested_price_cents].to_i)
              errors.add(:base, "The suggested price you entered was too low.")
              raise Link::LinkInvalid, "The suggested price you entered was too low."
            end
          end
        end

        # error if missing pricing info for the product's default recurrence
        if product.subscription_duration.present? && (
          !variant[:recurrence_price_values][product.subscription_duration.to_s].present? ||
          !variant[:recurrence_price_values][product.subscription_duration.to_s][:enabled]
        )
          errors.add(:base, "Please provide a price for the default payment option.")
          raise Link::LinkInvalid, "Please provide a price for the default payment option."
        end
      end

      # error if variants have different recurrence options:
      # 1. Extract variant recurrence selections:
      # Ex. [["monthly", "yearly"], ["monthly"]]
      enabled_recurrences_for_variants = variants.map do |variant|
        variant[:recurrence_price_values].select { |k, v| v[:enabled] }.keys.sort
      end
      # 2. Ensure that they match
      # Ex. ["monthly", "yearly"] != ["monthly"] raises error
      enabled_recurrences_for_variants.each_with_index do |recurrences, index|
        next_recurrences = enabled_recurrences_for_variants[index + 1]
        if next_recurrences && recurrences != next_recurrences
          errors.add(:base, "All tiers must have the same set of payment options.")
          raise Link::LinkInvalid, "All tiers must have the same set of payment options."
        end
      end
    end
end
