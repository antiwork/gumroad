# frozen_string_literal: true

class Product::VariantsUpdaterService
  attr_reader :product, :skus_params, :confirmed_removed_variant_ids, :payload_page_ids, :confirmed_removed_rich_content_ids, :preserved_rich_content_ids, :rewrite_budget, :deletion_guard_diagnostics, :id_mappings, :legacy_dead_file_embed_ids_by_rich_content_id, :deletion_audit_context, :contract
  attr_accessor :variants_params

  delegate :price_currency_type,
           :skus_enabled,
           :variant_categories_alive,
           :skus, to: :product

  # confirmed_removed_variant_ids: external ids of variants the seller explicitly
  # deleted in the editor (via the "Remove version" confirmation). Deleting a
  # variant that still has content (rich content pages or files) is only allowed
  # when its id is in this list — this protects sellers from a save payload
  # built from outdated or incomplete data silently wiping their whole version
  # tree. One production product was wiped three times in nine days (July
  # 13/18/21, 2026); July 21 was a server-induced blind editor state, and the
  # July 13/18 client trigger is unknown — see Product::RichContentDeletionGuard
  # for the full history.
  # payload_page_ids / confirmed_removed_rich_content_ids feed the analogous
  # guard for page deletions (Product::RichContentDeletionGuard).
  # preserved_rich_content_ids: version-level pages the seller chose to KEEP in
  # the hidden-content conflict dialog — absent from the payload (the
  # shared-content flag hides them from the editor) but never to be deleted.
  # rewrite_budget: the SHARED request-wide rewrite allowance built once by
  # Product::RichContentDeletionGuard.build_rewrite_budget — pass the same hash
  # to every service in the save so a resubmitted page can only authorize one
  # deletion across all scopes, not one per scope.
  # deletion_guard_diagnostics: non-PII counts/flags captured before the save
  # mutated anything, attached to every blocked-save notification.
  # id_mappings: per-request accumulator of client id → canonical server id for
  # newly created variants and pages, returned to the editor after the save.
  # legacy_dead_file_embed_ids_by_rich_content_id: a pre-mutation snapshot used
  # to repair destination pages created by editor move/copy flows.
  # deletion_audit_context: :actor_user_id, :request_id and :revision_token for
  # the deletion audit trail (ProductVariantDeletionAudit), threaded down rather
  # than read from a global so these services still work off-request.
  # +contract+ - optional Product::SaveContract (gumroad-private#1379), supplied
  # only by the editor's save path. nil preserves the legacy behaviour.
  def initialize(product:, variants_params:, skus_params: {}, confirmed_removed_variant_ids: [], payload_page_ids: [], confirmed_removed_rich_content_ids: [], preserved_rich_content_ids: [], rewrite_budget: {}, deletion_guard_diagnostics: {}, id_mappings: nil, legacy_dead_file_embed_ids_by_rich_content_id: {}, deletion_audit_context: {}, contract: nil)
    @product = product
    @variants_params = variants_params
    @skus_params = skus_params.values
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

  def perform
    self.variants_params = clean_variants_params(variants_params)

    existing_categories = variant_categories_alive.to_a
    keep_categories = []

    # Resolved BEFORE the loop below, because that loop soft-deletes the versions
    # this save names. Read afterwards, every named version looks dead and the
    # alive-only filter inside would no longer tell "the version this request is
    # deleting" apart from "a version deleted in some earlier save".
    named_version_ids = contract_named_alive_version_ids(existing_categories)

    variants_params.each do |category|
      variant_category_updater = Product::VariantCategoryUpdaterService.new(
        product:,
        category_params: category,
        contract:,
        confirmed_removed_variant_ids:,
        payload_page_ids:,
        confirmed_removed_rich_content_ids:,
        preserved_rich_content_ids:,
        rewrite_budget:,
        deletion_guard_diagnostics:,
        id_mappings:,
        legacy_dead_file_embed_ids_by_rich_content_id:,
        deletion_audit_context:
      )
      variant_category = variant_category_updater.perform
      keep_categories << variant_category if category[:id].present?
    end

    # Product::SaveContract, Rule 2. Same substitution as inside the category
    # updater: a grouping absent from the payload is not an instruction to
    # delete it. Under the contract, only groupings the client named — or a
    # clear-all — are swept.
    categories_to_delete = contract_scoped_category_deletions(existing_categories - keep_categories, existing_categories, named_version_ids)
    categories_to_delete.each do |variant_category|
      # NOTE (gumroad-private#1379, ruling item 4): this `next` skips the whole
      # branch for a grouping whose versions have purchases — including the
      # `mark_deleted!` below, so nothing is actually deleted and the effect is
      # safe. But it reads as "purchased groupings are exempt from the intent
      # check", which is backwards and one refactor away from real data loss.
      # Renamed the condition to say what it means: purchased groupings are not
      # swept at all.
      next if grouping_protected_from_sweep?(variant_category)

      # Captured before the sweep: these are the versions whose removal this
      # operation authorises, and the same list the guard checks.
      variants_to_sweep = variant_category.alive_variants.to_a
      affected_variant_external_ids = variants_to_sweep.map(&:external_id)

      Product::VariantCategoryUpdaterService.ensure_deletion_intent!(
        product:,
        variants: variants_to_sweep,
        confirmed_removed_variant_ids:,
        diagnostics: deletion_guard_diagnostics
      )
      # The versions go with their grouping. VariantCategory's `has_many
      # :variants` has no `dependent:` option, so `mark_deleted!` alone leaves
      # them alive under a deleted grouping — a state no editor query expects,
      # which broke both loading and saving the product carrying it
      # (gumroad-private#1784). The guard above authorised removing exactly
      # this list, and the shared deletion path also schedules the cleanup of
      # their pages, so nothing live is left hanging off the dead grouping.
      deleted_variant_external_ids = Product::VariantCategoryUpdaterService.batch_delete_variants(
        product:,
        variants: variants_to_sweep
      )
      variant_category.mark_deleted!

      # `alive_child_variant_count` predates the version sweep above and now
      # records 0 for new rows; kept so old audit rows stay interpretable.
      # Intent is judged against the versions this sweep AUTHORISED removing
      # (`affected_variant_external_ids`) — a version an earlier save already
      # deleted is not attributed to this request.
      ProductVariantDeletionAudit.record_deletion(
        actor_user_id: deletion_audit_context[:actor_user_id],
        product_id: product.id,
        route: ProductVariantDeletionAudit::EDITOR_CATEGORY_SWEPT,
        deleted_variant_external_ids:,
        deleted_variant_category_external_ids: [variant_category.external_id],
        affected_variant_external_ids: affected_variant_external_ids,
        confirmed_removed_variant_ids:,
        alive_child_variant_count: variant_category.variants.alive.count,
        revision_token: deletion_audit_context[:revision_token],
        correlation_id: deletion_audit_context[:correlation_id],
        request_id: deletion_audit_context[:request_id],
      )
    end

    begin
      Product::SkusUpdaterService.new(product:, skus_params:).perform if skus_enabled
    rescue ActiveRecord::RecordInvalid => e
      product.errors.add(:base, e.message)
      raise e
    end
  end

  private
    # Primary keys of the ALIVE versions of this product that the save contract
    # names for deletion. Must be called before the payload loop runs, while
    # those versions are still alive — see the call site.
    def contract_named_alive_version_ids(existing_categories)
      return Set.new unless contract&.enforced?
      # A clear-all is not an id interpretation, so the consumer below never
      # consults this set on that path — skip the query rather than run it for
      # a caller that will short-circuit before reading it.
      return Set.new if contract.cleared?(:variants)

      ids = contract.deleted_ids(:variants)
      return Set.new if ids.empty?

      BaseVariant.alive
                 .where(variant_category_id: existing_categories.map(&:id))
                 .where(id: ids.filter_map { BaseVariant.from_external_id(_1) })
                 .pluck(:id)
                 .to_set
    end

    # Narrows the diff-derived sweep set to what the contract authorises.
    # Untouched when no contract is supplied or the flag is off.
    def contract_scoped_category_deletions(diff_deletions, existing_categories, named_version_ids)
      return diff_deletions unless contract&.enforced?
      return existing_categories if contract.cleared?(:variants)

      ids = contract.deleted_ids(:variants)
      return [] if ids.empty?

      # Deleted ids name versions OR groupings — the editor removes a whole
      # grouping by naming it, and removes versions by naming them. A grouping
      # is swept only when it is named directly.
      #
      # An external id does not say WHICH KIND of row it names. `external_id` is
      # `ObfuscateIds.encrypt(id)` of the primary key with nothing mixed in to
      # identify the table (see ExternalId), and `variants` and
      # `variant_categories` are separate tables with independent auto-increment
      # counters. So a version and a grouping whose primary keys happen to line
      # up have the SAME external id string — an everyday coincidence, not an
      # exotic one, and the reason the save-contract controller test covering a
      # second grouping was intermittently red.
      #
      # Matching every named id against grouping external ids therefore let a
      # request that deletes one VERSION sweep an unrelated GROUPING whose
      # primary key collided with that version's, taking every version in it and
      # leaving the version the seller actually named alive. When an id names a
      # version of this product, read it as a version: that is what the editor
      # meant, and it is the interpretation that cannot destroy data the seller
      # never mentioned.
      #
      # `named_version_ids` holds only versions that were ALIVE when the save
      # started. A version deleted by some EARLIER save is not something this
      # editor can be naming — it is already gone — so letting a dead row win the
      # tie would silently cancel the deletion of the grouping the seller did
      # name, leaving it and everything in it alive while the response says the
      # save succeeded.
      existing_categories.select do |category|
        ids.include?(category.external_id) && !named_version_ids.include?(category.id)
      end
    end

    # A grouping whose versions have purchases is never swept by omission. This
    # is a protection, not a guard exemption — see the call site.
    def grouping_protected_from_sweep?(variant_category)
      variant_category.has_alive_grouping_variants_with_purchases?
    end

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
            new_option = option.slice(:id, :temp_id, :client_id, :name, :description, :url, :customizable_price, :recurrence_price_values, :max_purchase_count, :integrations, :rich_content, :apply_price_changes_to_existing_memberships, :subscription_price_change_effective_date, :subscription_price_change_message, :duration_in_minutes)

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
