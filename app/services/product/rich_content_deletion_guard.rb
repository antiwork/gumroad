# frozen_string_literal: true

# Blocks a product-editor save from deleting content pages the seller didn't
# explicitly delete. The editor always submits the FULL list of pages, so a page
# that exists in the database but is missing from the payload normally means the
# seller deleted it in the UI. But a payload built from outdated or incomplete
# data silently soft-deletes every page it doesn't know about — wiping the
# seller's product content in a single ordinary save.
#
# This guard exists because one production product had its content wiped three
# times in nine days (July 13, 18 and 21, 2026). The July 21 wipe was
# server-induced, not a stale browser tab: support had restored the product's
# per-version pages while has_same_rich_content_for_all_variants stayed on, so
# a fresh editor load received empty variant content — the stored state itself
# produced a blind payload (see Link#recoverable_hidden_variant_rich_content?).
# The July 13/18 client-side trigger was never identified (the request bodies
# were not retained). The guard is therefore deliberately trigger-agnostic: ANY
# save that would delete visible content without a matching intent signal is
# blocked, whatever produced the payload.
#
# A page deletion is considered intentional when either:
# - the page's id appears elsewhere in the same payload (the page moved between
#   the product level and a variant, e.g. when toggling "use the same content
#   for all versions"),
# - the page's exact content appears in the payload under an id the server
#   doesn't know. Before the server started returning canonical ids to the
#   editor after each save, pages created in an editor session kept their
#   client-generated ids across saves, so the second save of such a page
#   arrived with an unknown id and the server re-created it — a rewrite, not a
#   deletion. A blind wipe doesn't resubmit the content, so it stays blocked.
#   Matching is count-aware: N identical unknown-id payload pages can only
#   account for N deleted pages, so a duplicate-content page omitted by an
#   outdated payload can't hide behind its surviving twin. Or,
# - the seller confirmed the deletion in the editor (delete-page modal, copy
#   content from another version, discard other versions' content), which the
#   client reports via confirmed_removed_rich_content_ids.
#
# Pages without visible editor content (no title, and a description that is
# blank or only empty structural nodes like the single bare paragraph the
# editor creates as a placeholder) are deletable without confirmation — they
# carry nothing a buyer could see, and the editor legitimately drops them in
# several flows.
class Product::RichContentDeletionGuard
  MESSAGE = "This save would remove content pages that weren't explicitly deleted. The content shown in the editor may be out of date — please refresh the page and try again."

  # The July 21 incident shape, caught before any damage: the persisted
  # shared-content flag hid real version-level pages from the editor session
  # that produced this save, and the product level is blank. Refreshing
  # genuinely recovers here — the editor now serves the hidden pages in this
  # state (see Link#recoverable_hidden_variant_rich_content?).
  HIDDEN_CONTENT_RECOVERABLE_MESSAGE = "This product's versions have content pages that weren't loaded into this editor session. Refresh the page to load them, review, and save again."

  # Same hidden version-level pages, but the product level ALSO has visible
  # content, so there's no safe side to pick automatically. The save fails
  # closed; the editor offers the seller an explicit choice (keep the
  # product-level content and delete the hidden pages, or cancel) via the
  # structured payload on HiddenVariantContentConflict.
  HIDDEN_CONTENT_CONFLICT_MESSAGE = "This product's versions still have their own content pages, which aren't shown because the product is set to use the same content for all versions. Saving would permanently delete them, so an explicit choice is required."

  # Raised for the fail-closed conflict case. Carries the hidden pages so the
  # controller can return them and the editor can present the explicit choice.
  class HiddenVariantContentConflict < Link::LinkInvalid
    attr_reader :hidden_pages

    def initialize(message, hidden_pages:)
      @hidden_pages = hidden_pages
      super(message)
    end
  end

  # rewrite_budget: the shared allowance built by .build_rewrite_budget for the
  # whole save request. The guard runs several times per save (once for the
  # product-level pages, once per variant), so the SAME hash must be passed to
  # every call — building a fresh budget per call would let one resubmitted
  # page account for one omitted stored page in each scope instead of one
  # total. Entries are consumed (mutated) as they authorize rewrites.
  #
  # diagnostics: non-PII counts and flags captured by the controller BEFORE the
  # save mutated anything (see LinksController#deletion_guard_diagnostics).
  # Included in the blocked-save notification so an incident like July 21 is
  # diagnosable from the alert alone, and used to classify hidden-content
  # blocks via the persisted shared-content flag.
  def self.ensure_intent!(product:, rich_contents_to_delete:, payload_page_ids:, confirmed_removed_ids:, rewrite_budget: {}, diagnostics: {})
    unconfirmed = rich_contents_to_delete.select do |rich_content|
      next false unless rich_content.has_editor_content?
      next false if payload_page_ids.include?(rich_content.external_id)
      next false if confirmed_removed_ids.include?(rich_content.external_id)

      normalized = normalize_description(rich_content.description.as_json)
      if rewrite_budget[normalized].to_i > 0
        rewrite_budget[normalized] -= 1
        next false
      end
      true
    end
    return if unconfirmed.empty?

    # Version-level pages being deleted while the PERSISTED shared-content
    # flag is on were invisible to the editor session that produced this save
    # — the exact July 21 mechanism — so they get a specific error instead of
    # the generic "editor may be out of date" one.
    hidden_variant_pages =
      diagnostics[:persisted_has_same_rich_content_for_all_variants] ? unconfirmed.select { |rich_content| rich_content.entity.is_a?(BaseVariant) } : []

    if hidden_variant_pages.any?
      # Classify from the PRE-SAVE state captured in the diagnostics, never
      # from the live rows: by the time the per-variant guards run, the save's
      # transaction has already applied the product-level page changes, so a
      # save that CLEARED the product-level content would make the live rows
      # look blank and misclassify a real conflict as "recoverable". The
      # transaction then rolls back, restores the product-level content, and a
      # refresh returns the seller to the exact same dead end.
      product_side_has_content = diagnostics[:persisted_product_level_has_editor_content]
      if product_side_has_content
        block_save!(product:, unconfirmed:, diagnostics:,
                    error_name: "Blocked product save that would delete version content hidden by the shared-content flag (conflicting product-level content)",
                    message: HIDDEN_CONTENT_CONFLICT_MESSAGE,
                    exception: HiddenVariantContentConflict.new(HIDDEN_CONTENT_CONFLICT_MESSAGE, hidden_pages: hidden_variant_pages.map { { id: _1.external_id, title: _1.title } }))
      else
        block_save!(product:, unconfirmed:, diagnostics:,
                    error_name: "Blocked product save that would delete version content hidden by the shared-content flag (recoverable)",
                    message: HIDDEN_CONTENT_RECOVERABLE_MESSAGE)
      end
    end

    block_save!(product:, unconfirmed:, diagnostics:,
                error_name: "Blocked product save that would delete content pages without confirmation",
                message: MESSAGE)
  end

  # Builds the request-wide rewrite allowance from the unknown-id payload page
  # descriptions: each unknown-id payload page can account for at most one
  # deleted stored page (the one it rewrites), so track a consumable count per
  # normalized description. Build this ONCE per save request and pass the same
  # hash to every ensure_intent! call so the allowance is shared across the
  # product-level and per-variant guard invocations.
  def self.build_rewrite_budget(payload_page_descriptions)
    Array.wrap(payload_page_descriptions).map { |description| normalize_description(description) }.tally
  end

  # File ids inside fileEmbed nodes are rewritten between client and server
  # representations of the same file (the client may hold the hex id while the
  # stored page holds the base64 external id), so they can't be compared
  # directly. The embed's uid — a stable client-generated identity — stays the
  # same, so content comparison drops the id and keeps everything else.
  def self.normalize_description(description)
    case description
    when Array then description.map { |node| normalize_description(node) }
    when Hash then description.except("id", :id).transform_values { |value| normalize_description(value) }
    else description
    end
  end

  def self.block_save!(product:, unconfirmed:, diagnostics:, error_name:, message:, exception: nil)
    ErrorNotifier.notify(
      error_name,
      product_id: product.id,
      rich_content_ids: unconfirmed.map(&:id),
      **diagnostics
    )
    product.errors.add(:base, message)
    raise exception || Link::LinkInvalid.new(message)
  end
  private_class_method :block_save!
end
