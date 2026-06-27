# frozen_string_literal: true

# Ai::StoreAgentActionExecutor applies a write action that the seller has explicitly confirmed in the
# Agent chat UI. The agent service only ever *proposes* actions; this is the single place a store
# mutation actually happens, and it deliberately re-validates everything rather than trusting the
# proposal:
#   - It re-resolves every product/discount by external_id scoped to the seller, so a tampered or
#     stale id can't touch another seller's data.
#   - It runs the SAME Pundit authorization the equivalent controller action runs, so the agent can
#     never do something the seller couldn't do by hand.
#   - It validates the action type against an allowlist; an unknown type is rejected, not guessed.
#
# Returns { success:, message: } and never raises for expected validation failures.
class Ai::StoreAgentActionExecutor
  SUPPORTED_TYPES = %w[create_discount update_product_price publish_product unpublish_product].freeze

  def initialize(seller:, pundit_user:)
    @seller = seller
    @pundit_user = pundit_user
  end

  # @param type [String] one of SUPPORTED_TYPES
  # @param params [Hash] the params from the confirmed proposed action
  # @return [Hash] { success: Boolean, message: String }
  def execute(type:, params:)
    params = (params || {}).with_indifferent_access
    case type.to_s
    when "create_discount" then create_discount(params)
    when "update_product_price" then update_product_price(params)
    when "publish_product" then set_published(params, published: true)
    when "unpublish_product" then set_published(params, published: false)
    else
      failure("That action isn't supported.")
    end
  rescue Pundit::NotAuthorizedError
    failure("You don't have permission to do that.")
  rescue ActiveRecord::RecordInvalid => e
    failure(e.record&.errors&.full_messages&.first || "That change couldn't be saved.")
  end

  private
    attr_reader :seller, :pundit_user

    def create_discount(params)
      authorize!([:checkout, OfferCode], :create?)

      code = params[:code].to_s.strip
      return failure("A discount code is required.") if code.blank?

      # A universal percentage code must stay currency-agnostic: setting currency_type would scope it
      # (via OfferCode.universal_with_matching_currency) to only one currency's products, so a
      # multi-currency seller would get a "universal" percent code that silently skips some products.
      # Only fixed-amount codes carry a currency.
      attributes = { code:, universal: true }
      if params[:percent_off].present?
        percent = params[:percent_off].to_i
        return failure("Percentage off must be between 1 and 100.") unless percent.between?(1, 100)
        attributes[:amount_percentage] = percent
      elsif params[:amount_off_cents].present?
        cents = params[:amount_off_cents].to_i
        return failure("Discount amount must be greater than zero.") unless cents.positive?
        attributes[:amount_cents] = cents
        attributes[:currency_type] = seller.currency_type
      else
        return failure("Provide a percentage or a fixed amount off.")
      end

      offer_code = seller.offer_codes.build(attributes)
      if offer_code.save
        success("Created discount code #{offer_code.code}.")
      else
        failure(offer_code.errors.full_messages.first || "That discount couldn't be created.")
      end
    end

    def update_product_price(params)
      product = find_product(params[:product_id])
      return failure("I couldn't find that product.") if product.nil?
      authorize!(product, :update?)
      # Mirror the service guard: tiered/variant-priced products keep their buyer-visible price on
      # tiers/variants, so writing the flat price_cents would report success without changing what
      # buyers pay. Reject here too so a replayed/tampered action can't slip past.
      if product.is_tiered_membership? || product.alive_variants.exists?
        return failure("That product is priced per tier/version and can't be changed from here.")
      end

      new_price_cents = params[:new_price_cents].to_i
      return failure("Price must be zero or greater.") if new_price_cents.negative?

      if product.update(price_cents: new_price_cents)
        success("Updated the price of \"#{product.name}\".")
      else
        failure(product.errors.full_messages.first || "That price couldn't be saved.")
      end
    end

    def set_published(params, published:)
      product = find_product(params[:product_id])
      return failure("I couldn't find that product.") if product.nil?
      authorize!(product, published ? :publish? : :unpublish?)

      if published
        return failure("Add an email to your account before publishing a product.") if product.user.email.blank?
        product.publish!
        success("Published \"#{product.name}\".")
      else
        product.unpublish!
        success("Unpublished \"#{product.name}\".")
      end
    rescue Link::LinkInvalid
      failure(product.errors.full_messages.first || "That product can't be published yet.")
    end

    def find_product(external_id)
      return nil if external_id.blank?
      # Mirror the service's scope (visible_and_not_archived) so a confirmed action carrying an
      # archived product id — which the listing tool never surfaces — can't mutate it.
      seller.products.visible_and_not_archived.find_by_external_id(external_id.to_s)
    end

    # Mirror controller-style authorization so the agent is bound by the seller's real permissions.
    def authorize!(record, query)
      policy = Pundit.policy!(pundit_user, record)
      raise Pundit::NotAuthorizedError, query: query, record: record unless policy.public_send(query)
    end

    def success(message) = { success: true, message: }
    def failure(message) = { success: false, message: }
end
