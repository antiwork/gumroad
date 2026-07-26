# frozen_string_literal: true

# Checks the *shape* of a product-editor save payload before the save touches
# anything, so a structurally broken request is described precisely instead of
# being handed to the content deletion guards.
#
# Why this runs first: the deletion guards (Product::RichContentDeletionGuard,
# Product::VariantCategoryUpdaterService.ensure_deletion_intent!) answer one
# question — "would this save remove content the seller didn't ask to remove?"
# A malformed payload trips them for the wrong reason. If a save sends its
# content pages as something other than a list, the server reads that as "the
# payload doesn't know about these pages" and returns the deletion guard's "the
# content shown in the editor may be out of date — please refresh the page"
# message. Refreshing does not help, because the payload was never a stale
# snapshot: it was invalid. The seller retries, gets the same message, and
# support gets a ticket that looks like a staleness bug.
#
# So the ordering is: shape validation (here) → content guards → mutation. This
# does NOT relax the guards or move them relative to the mutation; they still run
# pre-mutation exactly as before. It only makes sure a payload that can't be
# interpreted at all fails with its own reason.
#
# Deliberately NOT checked here: whether the ids in the payload name records of
# this product. That sounds like a shape question but it is not answerable yet.
# A page the seller just created in the editor is submitted under a
# client-generated id that the server has never seen — that is the normal,
# supported flow (the save response hands back `rich_content_id_mappings` so the
# editor can adopt canonical ids afterwards). An unrecognised id is therefore
# indistinguishable from a genuinely foreign one until client ids are namespaced
# per owner and minted uniquely per copy, which is the identity-contract work in
# gumroad-private#1360. Adding the check before that lands rejects legitimate
# first saves of new content, which is strictly worse than the confusing message
# this class exists to fix.
#
# Everything checked here is a client bug, never something a seller can cause by
# editing their product, so each failure is also reported to Sentry — a spike is
# the signal that an editor build is emitting bad payloads.
class Product::SavePayloadShapeValidator
  # Raised before any mutation. Carries a stable code so the editor can tell a
  # malformed-payload rejection apart from a staleness or deletion-intent one.
  class InvalidPayload < StandardError
    ERROR_CODE = "invalid_payload_shape"

    attr_reader :reason

    def initialize(message, reason:)
      @reason = reason
      super(message)
    end
  end

  PAGES_NOT_A_LIST = "This save couldn't be applied because its content pages weren't sent as a list. Reload the page and try again."
  VARIANTS_NOT_A_LIST = "This save couldn't be applied because its versions weren't sent as a list. Reload the page and try again."

  # product: the product being saved, for the Sentry report.
  #
  # raw_params: the unfiltered request params. Strong parameters silently DROPS a
  # value whose shape doesn't match the policy (a scalar where an array of hashes
  # is declared), so by the time a payload reaches the permitted params a
  # malformed collection is simply absent — indistinguishable from "the client
  # didn't send it", which is what made these requests read as content deletions
  # in the first place. The raw params are the only place the bad shape is still
  # visible.
  def self.validate!(product:, raw_params:)
    new(product:, raw_params:).validate!
  end

  def initialize(product:, raw_params:)
    @product = product
    @raw_params = raw_params
  end

  def validate!
    pages = raw_params[:rich_content]
    reject!(PAGES_NOT_A_LIST, reason: "pages_not_a_list") unless pages.nil? || pages.is_a?(Array)

    variants = raw_params[:variants]
    reject!(VARIANTS_NOT_A_LIST, reason: "variants_not_a_list") unless variants.nil? || variants.is_a?(Array)

    Array.wrap(variants).each do |variant|
      next reject!(VARIANTS_NOT_A_LIST, reason: "variant_not_a_hash") unless variant.is_a?(ActionController::Parameters) || variant.is_a?(Hash)

      variant_pages = variant[:rich_content]
      reject!(PAGES_NOT_A_LIST, reason: "variant_pages_not_a_list") unless variant_pages.nil? || variant_pages.is_a?(Array)
    end
  end

  private
    attr_reader :product, :raw_params

    def reject!(message, reason:)
      ErrorNotifier.notify(
        "Rejected product save with a malformed payload",
        product_id: product.id,
        reason:,
      )
      raise InvalidPayload.new(message, reason:)
    end
end
