# frozen_string_literal: true

class Product::VariantCategoryUpdaterService
  include CurrencyHelper

  # Distinct from ActiveRecord::RecordNotFound so the per-variant rescue in
  # `perform` can't also catch a downstream missing-record failure (e.g. a
  # missing ProductFile) raised later in the same begin block.
  StaleVariantReferenceError = Class.new(StandardError)

  attr_reader :product, :category_params, :confirmed_removed_variant_ids, :payload_page_ids, :confirmed_removed_rich_content_ids, :preserved_rich_content_ids, :rewrite_budget, :deletion_guard_diagnostics, :id_mappings, :legacy_dead_file_embed_ids_by_rich_content_id, :deletion_audit_context, :contract
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

  # id_mappings: a per-request accumulator the controller passes down and
  # returns to the editor after a successful save. It maps client-generated ids
  # to canonical variant/page ids and records file embeds removed from stored
  # pages, so the editor's next save addresses the same records and sends the
  # same content the server persisted.
  # legacy_dead_file_embed_ids_by_rich_content_id: a pre-mutation snapshot of
  # dead foreign ids in this product's stored pages. New destination pages use
  # it only when their payload identifies a stored source page.
  # deletion_audit_context: who and which request is deleting, for the audit
  # trail (ProductVariantDeletionAudit). Carries :actor_user_id, :request_id and
  # :revision_token. Passed down the same way as deletion_guard_diagnostics
  # rather than read from a global, so the services stay usable outside a
  # request (backfills, console, tests). Defaults to empty: a caller that
  # doesn't know the actor still deletes normally, it just records less.
  # +contract+ - optional Product::SaveContract (gumroad-private#1379). Only the
  # product editor's save path supplies one; nil means the legacy diff-derived
  # behaviour, so every other caller is unchanged by construction.
  def initialize(product:, category_params:, confirmed_removed_variant_ids: [], payload_page_ids: [], confirmed_removed_rich_content_ids: [], preserved_rich_content_ids: [], rewrite_budget: {}, deletion_guard_diagnostics: {}, id_mappings: nil, legacy_dead_file_embed_ids_by_rich_content_id: {}, deletion_audit_context: {}, contract: nil)
    @product = product
    @category_params = category_params
    @confirmed_removed_variant_ids = Array.wrap(confirmed_removed_variant_ids)
    @payload_page_ids = Array.wrap(payload_page_ids)
    @confirmed_removed_rich_content_ids = Array.wrap(confirmed_removed_rich_content_ids)
    @preserved_rich_content_ids = Array.wrap(preserved_rich_content_ids)
    @rewrite_budget = rewrite_budget
    @deletion_guard_diagnostics = deletion_guard_diagnostics
    @id_mappings = id_mappings || {
      variants: {},
      rich_content: {},
      rich_content_by_scope: Hash.new { |scopes, scope| scopes[scope] = {} },
      removed_file_embeds: {},
    }
    @legacy_dead_file_embed_ids_by_rich_content_id = legacy_dead_file_embed_ids_by_rich_content_id
    @deletion_audit_context = deletion_audit_context || {}
    @contract = contract
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

  # Soft-deletes variants and schedules the cleanup of their pages and
  # archives. Returns the external ids of the variants this call actually
  # deleted — narrower than +variants+, because a variant an earlier save
  # already deleted keeps its original deletion timestamp (support uses that
  # timestamp to find which rows a bad save wiped).
  #
  # A class method because both this service (versions omitted from a
  # submitted grouping) and Product::VariantsUpdaterService (a whole grouping
  # swept because the payload never mentioned it) delete versions and must do
  # it the same way — the sweep used to mark only the grouping deleted, which
  # left its versions alive under a deleted parent (gumroad-private#1784).
  def self.batch_delete_variants(product:, variants:)
    variant_ids = variants.respond_to?(:pluck) ? variants.pluck(:id) : variants.map(&:id)
    return [] if variant_ids.empty?

    now = Time.current
    newly_deleted = BaseVariant.where(id: variant_ids).alive.to_a
    BaseVariant.where(id: newly_deleted.map(&:id)).update_all(deleted_at: now, updated_at: now) if newly_deleted.any?

    # Cleanup runs for every id, including ones deleted earlier: an earlier
    # delete may not have finished cleaning up, and both workers are safe to
    # run twice.
    variant_ids.each do |variant_id|
      DeleteProductRichContentWorker.perform_async(product.id, variant_id)
      DeleteProductFilesArchivesWorker.perform_async(product.id, variant_id)
    end

    product.invalidate_cache
    # `update_all` above skips callbacks, so TouchesProductForPriceCache never fires and
    # `invalidate_cache` does not write `links`. Deleting the cheapest tier would otherwise
    # leave the storefront advertising its price (Pages::ProfileData keys on links.updated_at).
    product.touch if newly_deleted.any?

    newly_deleted.map(&:external_id)
  end

  def perform
    if category_params[:id].present?
      self.variant_category = variant_categories.find_by_external_id(category_params[:id])
      # Remembered before the update below blanks it. The "grouping wasn't
      # submitted" call carries no name, because historically it only ever ran
      # as a prelude to sweeping the whole grouping — blanking the title was
      # how that route marked the grouping gone. Under the contract the same
      # call can now be a partial deletion that leaves the grouping alive, and
      # the name has to survive that. See the restore below.
      original_title = variant_category.title
      variant_category.update(title: category_params[:title])
    else
      self.variant_category = variant_categories.build(title: category_params[:title])
    end

    if category_params[:options].nil?
      # Product::SaveContract, Rule 2, applied to the widest deletion route in
      # the editor. `options: nil` means "this grouping wasn't submitted", and
      # historically that swept every version in it. Under the contract a save
      # that names specific ids must remove only those, and a save that names
      # none must remove nothing at all — otherwise an explicit one-version
      # deletion arriving with an empty `variants` collection would take the
      # whole grouping with it.
      variants_to_delete = contract_scoped_category_deletions(variant_category.variants)
      self.class.ensure_deletion_intent!(product:, variants: variants_to_delete.select(&:alive?), confirmed_removed_variant_ids:, diagnostics: deletion_guard_diagnostics)
      deleted_variant_external_ids = batch_delete_variants(variants_to_delete)
      # The grouping itself only goes away when nothing is left in it. With the
      # contract off this is the same condition as before (the sweep deletes
      # everything, so nothing is alive), but a contract-scoped partial deletion
      # must leave the category standing for the versions that survive.
      category_was_deleted = variant_category.title.blank? && !variant_category.variants.alive.exists?
      variant_category.mark_deleted! if category_was_deleted
      # The grouping survived a route that assumed it would not, so give the
      # seller their name back. Unreachable with the contract off: there the
      # sweep always empties the grouping, so it is always deleted here.
      variant_category.update(title: original_title) if !category_was_deleted && variant_category.title.blank? && original_title.present?
      record_deletion_audit(
        route: ProductVariantDeletionAudit::EDITOR_CATEGORY_OMITTED,
        deleted_variant_external_ids:,
        deleted_variant_category_external_ids: category_was_deleted ? [variant_category.external_id] : [],
      )
    else
      existing_variants = variant_category.variants.to_a
      keep_variants = []
      validate_variant_recurrences!(category_params[:options])
      category_params[:options].each_with_index do |option, index|
        begin
          variant =
            begin
              create_or_update_variant!(option[:id],
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
            rescue StaleVariantReferenceError
              # Raised only by the lookup inside `create_or_update_variant!`
              # (via `find_by_external_id!`), never by anything downstream —
              # see that method for why a plain `ActiveRecord::RecordNotFound`
              # can't be rescued here without also mislabeling a later
              # missing-record failure (e.g. a missing `ProductFile`) as a
              # stale variant.
              errors.add(:base, "This save would remove content pages that weren't explicitly deleted. The content shown in the editor may be out of date — please refresh the page and try again.")
              raise Link::LinkInvalid
            end
          save_integrations(variant, option)
          visited_variant_external_ids << variant.external_id
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

      # Product::SaveContract, Rule 2. `existing - keep` infers deletion from
      # what the payload failed to mention; the contract replaces that with what
      # the client explicitly asked to remove. Under the contract, a version
      # missing from the payload is "no statement", not "delete me" — which is
      # what a stale tab, a truncated body, or a dropped malformed field
      # produces.
      variants_to_delete = contract_scoped_variant_deletions(existing_variants - keep_variants, existing_variants)
      self.class.ensure_deletion_intent!(product:, variants: variants_to_delete.select(&:alive?), confirmed_removed_variant_ids:, diagnostics: deletion_guard_diagnostics)
      record_deletion_audit(
        route: ProductVariantDeletionAudit::EDITOR_VARIANTS_DIFFED,
        deleted_variant_external_ids: batch_delete_variants(variants_to_delete),
      )
    end

    apply_unvisited_variant_scoped_deletions

    variant_category.save!
    variant_category
  end

  private
    # Version-scoped deletions (today: a version's integrations) name their
    # owner directly, so the payload can ask to disconnect an integration from
    # a version the `variants` list never mentions — a version the seller
    # didn't re-submit, or one living in a grouping the editor doesn't render
    # at all. Those versions are never visited by the loop above, which is
    # where `save_integrations` runs, so the request used to return success
    # while the integration stayed connected.
    #
    # This sweeps up exactly those: alive versions of THIS grouping that the
    # contract names as deletion owners and that the save has not already
    # visited. Nothing here can delete anything the payload didn't name — the
    # ids come from `variant_deleted_ids`, which is already freshness-gated.
    def apply_unvisited_variant_scoped_deletions
      return unless contract&.enforced?

      owner_ids = contract.variant_deletion_owner_ids - visited_variant_external_ids
      return if owner_ids.empty?

      variant_category.variants.alive.each do |variant|
        next unless owner_ids.include?(variant.external_id)

        apply_variant_scoped_integration_deletions(variant)
      end
    end

    # External ids of the versions the save actually walked through this run.
    # Only those had `save_integrations` applied to them.
    def visited_variant_external_ids
      @_visited_variant_external_ids ||= []
    end

    # The `options: nil` route — "this grouping wasn't submitted at all" —
    # scoped to what the contract authorises.
    #
    # With no contract, or with the flag off, this returns the whole grouping,
    # which is the legacy sweep unchanged. With the contract enforced the sweep
    # is only reachable through an explicit clear-all; a request naming specific
    # ids removes exactly those, and a request naming nothing removes nothing.
    # Without this the controller's explicit-deletion path would fall into the
    # branch below and delete every version in the first category while the
    # seller had asked for one.
    def contract_scoped_category_deletions(variants)
      return variants unless contract&.enforced?

      existing_variants = variants.to_a
      return existing_variants if contract.cleared?(:variants)

      ids = contract.deleted_ids(:variants)
      return [] if ids.empty?

      existing_variants.select { ids.include?(_1.external_id) }
    end

    # Narrows a diff-derived deletion set to what the contract authorises.
    # Returns the diff untouched when no contract is supplied or the flag is
    # off, so non-editor callers and the disabled path are byte-identical.
    #
    # A clear-all deletes from the PRE-SAVE set, not the diff, so it means
    # "everything that existed when the editor loaded" and cannot sweep up a
    # variant this same request just created.
    def contract_scoped_variant_deletions(diff_deletions, existing_variants)
      return diff_deletions unless contract&.enforced?
      return existing_variants if contract.cleared?(:variants)

      ids = contract.deleted_ids(:variants)
      return [] if ids.empty?

      existing_variants.select { ids.include?(_1.external_id) }
    end

    # Records a successful deletion for the audit trail. Never raises: see
    # ProductVariantDeletionAudit.
    def record_deletion_audit(route:, deleted_variant_external_ids: [], deleted_variant_category_external_ids: [])
      ProductVariantDeletionAudit.record_deletion(
        actor_user_id: deletion_audit_context[:actor_user_id],
        product_id: product.id,
        route:,
        deleted_variant_external_ids:,
        deleted_variant_category_external_ids:,
        confirmed_removed_variant_ids:,
        revision_token: deletion_audit_context[:revision_token],
        correlation_id: deletion_audit_context[:correlation_id],
        request_id: deletion_audit_context[:request_id],
      )
    end

    def batch_delete_variants(variants)
      self.class.batch_delete_variants(product:, variants:)
    end

    def create_or_update_variant!(external_id, params)
      return Variant.create!(params.slice(*ALLOWED_ATTRIBUTES)) if external_id.blank?

      begin
        variant = product.variants.find_by_external_id!(external_id)
      rescue ActiveRecord::RecordNotFound
        # The submitted variant id no longer resolves under this product —
        # e.g. the editor's in-memory snapshot still references a version
        # another session (or an earlier variant in the SAME save request,
        # via the deletion-audit/keep-variants bookkeeping) has since
        # deleted. Wrapped in its own class so callers can't also catch a
        # RecordNotFound raised later by save!/assign_attributes below.
        raise StaleVariantReferenceError
      end
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

    # Integrations enabled on a VERSION, as opposed to on the product.
    #
    # The checkbox model here is genuinely different from the product-level
    # integrations collection: the payload states the full enabled set for the
    # version, so "absent from the set" is how the editor has always expressed
    # "unchecked". That is a real statement, not an omission — but only when the
    # version actually submitted its integrations. When it did not, the
    # subtraction below reads "no integrations submitted" as "uncheck them all"
    # and silently tears down every version-level integration on the product.
    #
    # Scoped rather than excluded: the reviewer was right that leaving variant
    # integrations outside the contract needs a human ruling, so this brings
    # them in on the conservative reading — an unsubmitted `integrations` key
    # means no change, and an explicitly submitted set still behaves exactly as
    # it does today.
    def save_integrations(variant, option)
      enabled_integrations = []

      Integration::ALL_NAMES.each do |name|
        integration = product.find_integration_by_name(name)
        # `option[:integrations]` is client-controlled and may be any shape at
        # all. `dig` on a String raises TypeError (String has no #dig), which
        # inside the seller's save turns a malformed payload into a failed save
        # — so establish the shape before reading it rather than rescuing after.
        submitted = option[:integrations]
        enabled = submitted.respond_to?(:dig) ? submitted.dig(name) : nil
        # TODO: :product_edit_react cleanup
        if (enabled == "1" || enabled == true) && integration.present?
          enabled_integrations << integration
        end
      end

      if contract&.enforced?
        # Under the contract a version's integrations are removed only when the
        # payload names them for THIS version (owner-scoped, see
        # SaveContract#variant_deleted_ids). The submitted checkbox map is a
        # statement about what should be ON; it is not evidence that anything
        # missing from it was deliberately turned off, and treating it that way
        # let a stale tab silently disconnect an integration another tab had
        # just enabled — the join is not something the old flat contract or the
        # revision token could see.
        apply_variant_scoped_integration_deletions(variant)
        variant.active_integrations << enabled_integrations - variant.active_integrations
        return
      end

      deleted_integrations = variant.active_integrations - enabled_integrations
      variant.live_base_variant_integrations.where(integration: deleted_integrations).map(&:mark_deleted!)
      variant.active_integrations << enabled_integrations - variant.active_integrations
    end

    # Disconnects exactly the integrations the payload named for this version.
    # Split out of save_integrations because it also has to run for versions
    # the save never walked through — see
    # apply_unvisited_variant_scoped_deletions.
    def apply_variant_scoped_integration_deletions(variant)
      names_to_delete = contract.variant_deleted_ids(variant.external_id, :integrations)
      return if names_to_delete.empty?

      deleted_integrations = variant.active_integrations.select { _1.name.in?(names_to_delete) }
      variant.live_base_variant_integrations.where(integration: deleted_integrations).map(&:mark_deleted!)
    end

    # Parses the pre-serialized form, returning nil rather than raising when the
    # payload is not valid JSON.
    def parsed_variant_rich_content(value)
      JSON.parse(value, symbolize_names: true)
    rescue JSON::ParserError
      nil
    end

    # Narrows a diff-derived page deletion set to what the contract authorises.
    # Returns the diff untouched when no contract is supplied or the flag is
    # off, so behaviour is unchanged until the rollout reaches a seller.
    def contract_scoped_rich_content_deletions(diff_deletions, existing_rich_contents)
      return diff_deletions unless contract&.enforced?
      if contract.cleared?(:rich_content)
        return existing_rich_contents.reject { preserved_rich_content_ids.include?(_1.external_id) }
      end

      ids = contract.deleted_ids(:rich_content)
      return [] if ids.empty?

      existing_rich_contents.select { ids.include?(_1.external_id) }
        .reject { preserved_rich_content_ids.include?(_1.external_id) }
    end

    def save_rich_content(variant, option)
      # Product::SaveContract, Rule 1, applied to VERSION-level pages.
      #
      # The parse below turns an absent or malformed `rich_content` key into
      # `[]`, and the diff further down reads that as "delete every page on this
      # version". Under the contract the diff has no deletion authority, so an
      # absent collection still changes nothing. We must keep evaluating it,
      # though: an empty array can disappear in request encoding, and an
      # explicit fresh deletion (such as moving a version page to shared
      # content) still has to remove the named source row.
      submitted_rich_content = option[:rich_content]
      variant_rich_contents = if submitted_rich_content.is_a?(Array)
        submitted_rich_content
      elsif submitted_rich_content.is_a?(String)
        parsed = parsed_variant_rich_content(submitted_rich_content)
        parsed.is_a?(Array) ? parsed : []
      else
        []
      end
      rich_contents_to_keep = []
      existing_rich_contents = variant.alive_rich_contents.to_a
      variant_rich_contents.each.with_index do |variant_rich_content, index|
        rich_content = existing_rich_contents.find { |c| c.external_id == variant_rich_content[:id] } || variant.alive_rich_contents.build
        variant_rich_content[:description] = SaveContentUpsellsService.new(
          seller: variant.user,
          content: variant_rich_content[:description] || variant_rich_content[:content],
          old_content: rich_content.description || []
        ).from_rich_content
        rich_content.assign_attributes(title: variant_rich_content[:title].presence, description: variant_rich_content[:description].presence || [], position: index)
        legacy_source_id = variant_rich_content[:source_id].presence || variant_rich_content[:id]
        removed_file_embed_ids = rich_content.remove_stale_dead_cross_product_file_embeds(
          legacy_dead_file_ids: legacy_dead_file_embed_ids_by_rich_content_id[legacy_source_id]
        )
        rich_content.save!
        rich_contents_to_keep << rich_content
        id_mappings[:removed_file_embeds][rich_content.external_id] = removed_file_embed_ids if removed_file_embed_ids.any?
        # A page submitted under an id the server didn't know was just created
        # with a canonical id — report the mapping so the editor's next save
        # addresses this page instead of re-creating it.
        if variant_rich_content[:id].present? && variant_rich_content[:id] != rich_content.external_id
          id_mappings[:rich_content][variant_rich_content[:id]] = rich_content.external_id
          submitted_scope = option[:id].presence || option[:client_id]
          id_mappings[:rich_content_by_scope][submitted_scope][variant_rich_content[:id]] = rich_content.external_id
        end
      end
      rich_contents_to_delete = (existing_rich_contents - rich_contents_to_keep)
        .reject { preserved_rich_content_ids.include?(_1.external_id) }
      # Under the contract the diff stops being deletion authority: a page goes
      # only when the client named it, or asked to clear the collection.
      rich_contents_to_delete = contract_scoped_rich_content_deletions(rich_contents_to_delete, existing_rich_contents)
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
