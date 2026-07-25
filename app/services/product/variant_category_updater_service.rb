# frozen_string_literal: true

class Product::VariantCategoryUpdaterService
  include CurrencyHelper

  attr_reader :product, :category_params, :confirmed_removed_variant_ids, :payload_page_ids, :confirmed_removed_rich_content_ids, :preserved_rich_content_ids, :rewrite_budget, :deletion_guard_diagnostics, :id_mappings
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

  # id_mappings: a per-request accumulator ({ variants: {}, rich_content: {} })
  # the controller passes down and returns to the editor after a successful
  # save. New variants arrive with a client-generated id (client_id) and new
  # pages with a client-generated page id; the mappings tell the editor which
  # canonical server ids they got, so its next save addresses the same records
  # instead of re-creating them (and tripping the deletion guards).
  def initialize(product:, category_params:, confirmed_removed_variant_ids: [], payload_page_ids: [], confirmed_removed_rich_content_ids: [], preserved_rich_content_ids: [], rewrite_budget: {}, deletion_guard_diagnostics: {}, id_mappings: nil)
    @product = product
    @category_params = category_params
    @confirmed_removed_variant_ids = Array.wrap(confirmed_removed_variant_ids)
    @payload_page_ids = Array.wrap(payload_page_ids)
    @confirmed_removed_rich_content_ids = Array.wrap(confirmed_removed_rich_content_ids)
    @preserved_rich_content_ids = Array.wrap(preserved_rich_content_ids)
    @rewrite_budget = rewrite_budget
    @deletion_guard_diagnostics = deletion_guard_diagnostics
    @id_mappings = id_mappings || { variants: {}, rich_content: {} }
  end

  # Blocks deleting variants the seller has invested in — ones that carry
  # content (rich content pages or attached files), have been purchased, or
  # have non-default configuration (custom price, quantity cap, duration,
  # pay-what-you-want, integrations, recurring prices, description) — unless
  # the seller explicitly confirmed each removal in the editor. A save payload
  # built from outdated or incomplete data (see
  # Product::RichContentDeletionGuard for the incident history) would otherwise
  # treat every missing variant as "removed" and soft-delete the seller's
  # entire version tree. Truly blank rows (no content, no purchases, all
  # defaults) stay freely deletable so ordinary create-and-discard editor
  # flows keep working without extra confirmations.
  def self.ensure_deletion_intent!(product:, variants:, confirmed_removed_variant_ids:, diagnostics: {})
    unconfirmed = variants.reject do |variant|
      confirmed_removed_variant_ids.include?(variant.external_id) || !variant_requires_deletion_intent?(variant)
    end
    return if unconfirmed.empty?

    ErrorNotifier.notify(
      "Blocked product save that would delete configured, purchased, or content-bearing variants without confirmation",
      product_id: product.id,
      variant_ids: unconfirmed.map(&:id),
      **diagnostics
    )
    message = "This save would remove versions that still have content, settings, or sales, which weren't explicitly removed in the editor. The version list shown may be out of date — please refresh the page and try again."
    product.errors.add(:base, message)
    raise Link::LinkInvalid, message
  end

  def self.variant_requires_deletion_intent?(variant)
    variant_has_content?(variant) ||
      variant_has_purchases?(variant) ||
      variant_has_non_default_configuration?(variant)
  end

  def self.variant_has_content?(variant)
    # has_editor_content? (not description.present?) so a variant whose only
    # page is the editor's blank placeholder paragraph stays freely deletable.
    variant.alive_rich_contents.any?(&:has_editor_content?) || variant.has_files?
  end

  # Any successful purchase means buyers rely on this variant existing (their
  # library and receipts reference it), so deleting it must be an explicit
  # seller decision. This closes the gap where
  # VariantCategory#has_alive_grouping_variants_with_purchases? only shielded
  # the category-deletion path, and only when the variant also had files —
  # per-variant deletions of purchased, contentless variants were unguarded.
  def self.variant_has_purchases?(variant)
    variant.purchases.all_success_states.exists?
  end

  # A variant with settings that differ from a freshly-added blank row
  # represents real seller setup (pricing tiers configured before content is
  # added, for example) and must not be silently deletable by a stale payload.
  def self.variant_has_non_default_configuration?(variant)
    variant.price_difference_cents.to_i != 0 ||
      variant.customizable_price? ||
      variant.max_purchase_count.present? ||
      variant.duration_in_minutes.present? ||
      variant.description.present? ||
      variant.apply_price_changes_to_existing_memberships? ||
      variant.active_integrations.exists? ||
      (variant.respond_to?(:prices) && variant.prices.alive.where("price_cents > 0").exists?)
  end

  def perform
    if category_params[:id].present?
      self.variant_category = variant_categories.find_by_external_id(category_params[:id])
      variant_category.update(title: category_params[:title])
    else
      self.variant_category = variant_categories.build(title: category_params[:title])
    end

    if category_params[:options].nil?
      self.class.ensure_deletion_intent!(product:, variants: variant_category.variants.alive.to_a, confirmed_removed_variant_ids:, diagnostics: deletion_guard_diagnostics)
      batch_delete_variants(variant_category.variants)
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
        rescue Product::RichContentDeletionGuard::HiddenVariantContentConflict
          # Must reach the controller intact — it carries the hidden pages the
          # editor needs to offer the seller an explicit choice. The generic
          # re-raise below would flatten it into a plain Link::LinkInvalid.
          raise
        rescue ActiveRecord::RecordInvalid, Link::LinkInvalid, ArgumentError => e
          error_message = variant.present? ? variant.errors.full_messages.to_sentence : e.message
          errors.add(:base, error_message)
          raise Link::LinkInvalid
        end
        keep_variants << variant if option[:id]
        # Tell the editor which canonical id a newly created variant got, keyed
        # by the client-generated id it was submitted under, so subsequent
        # saves update this variant instead of re-creating it.
        id_mappings[:variants][option[:client_id]] = variant.external_id if option[:id].blank? && option[:client_id].present?
      end

      variants_to_delete = existing_variants - keep_variants
      self.class.ensure_deletion_intent!(product:, variants: variants_to_delete.select(&:alive?), confirmed_removed_variant_ids:, diagnostics: deletion_guard_diagnostics)
      batch_delete_variants(variants_to_delete)
    end

    variant_category.save!
    variant_category
  end

  private
    def batch_delete_variants(variants)
      variant_ids = variants.respond_to?(:pluck) ? variants.pluck(:id) : variants.map(&:id)
      return if variant_ids.empty?

      # Only stamp rows that are still alive. `variants` is derived from
      # `existing_variants - keep_variants`, which can include variants that were
      # already soft-deleted by an earlier save; an unscoped write would move
      # their `deleted_at` forward every time an unrelated save happened to
      # include them, making the timestamp describe the most recent save rather
      # than the deletion. Support relies on that timestamp to scope restores to
      # the window of the save that actually caused a wipe (see the restores in
      # gumroad-private#1230), and moving it drags unrelated rows into that
      # window. The deletion-intent guard just above is already scoped this way
      # -- it passes `variants_to_delete.select(&:alive?)` -- so this makes the
      # write agree with the guard that authorised it.
      now = Time.current
      already_deleted_ids = BaseVariant.where(id: variant_ids).where.not(deleted_at: nil).pluck(:id)
      variant_ids_to_delete = variant_ids - already_deleted_ids
      BaseVariant.where(id: variant_ids_to_delete).update_all(deleted_at: now, updated_at: now) if variant_ids_to_delete.any?

      # Cleanup still runs for every id in the batch: an earlier soft-delete may
      # have stamped the variant without its rich content or file archives being
      # cleaned up, and both workers are idempotent.
      variant_ids.each do |variant_id|
        DeleteProductRichContentWorker.perform_async(product.id, variant_id)
        DeleteProductFilesArchivesWorker.perform_async(product.id, variant_id)
      end

      product.invalidate_cache
    end

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
      elsif variant.apply_price_changes_to_existing_memberships? && (variant.flags_previously_changed? || variant.subscription_price_change_effective_date_previously_changed?)
        ErrorNotifier.notify("Not notifying subscribers of membership price change - tier: #{variant.id}; apply_price_changes_to_existing_memberships: #{variant.apply_price_changes_to_existing_memberships?}; subscription_price_change_effective_date: #{variant.subscription_price_change_effective_date}")
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
        # A page submitted under an id the server didn't know was just created
        # with a canonical id — report the mapping so the editor's next save
        # addresses this page instead of re-creating it.
        id_mappings[:rich_content][variant_rich_content[:id]] = rich_content.external_id if variant_rich_content[:id].present? && variant_rich_content[:id] != rich_content.external_id
      end
      rich_contents_to_delete = (existing_rich_contents - rich_contents_to_keep)
        .reject { preserved_rich_content_ids.include?(_1.external_id) }
      Product::RichContentDeletionGuard.ensure_intent!(
        product:,
        rich_contents_to_delete:,
        payload_page_ids:,
        confirmed_removed_ids: confirmed_removed_rich_content_ids,
        rewrite_budget:,
        diagnostics: deletion_guard_diagnostics
      )
      rich_contents_to_delete.map(&:mark_deleted!)
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
