# frozen_string_literal: true

# Moves a product (Link) from one seller to another, repointing every record that
# carries a denormalized owner reference while leaving historical/financial data with
# the origin account. See the "Product ownership transfer between accounts" issue for
# the full rationale.
#
# What moves:
#   - Link.user_id -> new seller
#   - Owner-keyed records that belong to the product: product/variant installments and
#     their workflows, product-scoped offer codes, UTM links, and the product's spot in
#     the origin seller's profile layout.
#
# What does NOT move (forward-only, by design):
#   - Purchases, refunds, balances, payouts, subscription events, 1099/tax attribution.
#     These stay with the origin account that actually received the money. As a result,
#     historical purchases keep seller_id = origin while link.user is now the new seller;
#     future purchases of the product are attributed to the new seller and stay
#     consistent. Followers are per-creator, not per-product, and also stay.
#
# What is detached rather than moved:
#   - Affiliate / collaborator / self-service-affiliate relationships are agreements
#     between an affiliate and the origin seller. They are detached from the product
#     instead of silently re-homed under the new seller, who can re-enroll the product.
#
# The repointing and the audit comments run in a single transaction so the move either
# happens completely or not at all. Cache invalidation and search reindexing run after
# commit.
class ProductOwnershipTransferService
  class TransferError < StandardError; end

  def initialize(product:, new_seller:, performed_by: nil, move_subscriptions: false)
    @product = product
    @new_seller = new_seller
    @previous_seller = product.user
    @performed_by = performed_by
    @move_subscriptions = move_subscriptions
  end

  def process
    validate_preconditions!

    ApplicationRecord.connection.stick_to_primary!
    ApplicationRecord.transaction do
      move_installments_and_workflows
      move_offer_codes
      move_utm_links
      move_subscriptions! if @move_subscriptions
      detach_affiliate_relationships
      move_product_page_sections
      remove_from_origin_profile
      repoint_product
      leave_audit_comments
    end

    rebuild_derived_data

    @product.reload
  end

  private
    attr_reader :product, :new_seller, :previous_seller, :performed_by

    def validate_preconditions!
      raise TransferError, "Product is required" if product.blank?
      raise TransferError, "New seller is required" if new_seller.blank?
      raise TransferError, "Product already belongs to the new seller" if previous_seller == new_seller
      raise TransferError, "New seller account is not in good standing" unless seller_in_good_standing?(new_seller)

      if custom_permalink_collides?
        raise TransferError, "New seller already has a product with the custom permalink \"#{product.custom_permalink}\""
      end
    end

    def seller_in_good_standing?(user)
      !user.deleted? && !user.suspended?
    end

    def custom_permalink_collides?
      return false if product.custom_permalink.blank?

      new_seller.links.where(custom_permalink: product.custom_permalink).where.not(id: product.id).exists?
    end

    # Product and variant installments (and the workflows that own them) are scoped to a
    # single product via link_id. Seller-wide posts (no link_id) stay with the origin.
    def move_installments_and_workflows
      product.workflows.update_all(seller_id: new_seller.id)
      product.installments
             .where(installment_type: [Installment::PRODUCT_TYPE, Installment::VARIANT_TYPE])
             .update_all(seller_id: new_seller.id)
    end

    # Offer codes that exist only for this product move with it. Universal codes and codes
    # shared with other products of the origin seller stay put; the moved product is just
    # detached from the shared ones so it no longer carries the origin seller's discount.
    def move_offer_codes
      product.offer_codes.to_a.each do |offer_code|
        if exclusive_to_product?(offer_code)
          offer_code.update!(user_id: new_seller.id)
        else
          product.offer_codes.delete(offer_code)
        end
      end
    end

    def exclusive_to_product?(offer_code)
      !offer_code.universal? && offer_code.product_ids.uniq == [product.id]
    end

    def move_utm_links
      UtmLink.where(seller_id: previous_seller.id, target_resource_type: "product_page", target_resource_id: product.id)
             .update_all(seller_id: new_seller.id)
    end

    def move_subscriptions!
      product.subscriptions.update_all(seller_id: new_seller.id)
    end

    # Affiliate, collaborator, and self-service-affiliate relationships are agreements
    # between an affiliate and the origin seller, not properties of the product, so we
    # detach the product from them instead of silently re-homing them under the new
    # seller. Destroying each ProductAffiliate triggers its own callbacks, which clear the
    # product's collab flag and remove the product from the affiliate's audience entry.
    def detach_affiliate_relationships
      product.product_affiliates.each(&:destroy!)
      SelfServiceAffiliateProduct.where(product_id: product.id).destroy_all
    end

    # Sections scoped to the product (its own page layout) belong to the product and
    # travel with it; only their denormalized seller_id needs to follow the new owner.
    def move_product_page_sections
      product.seller_profile_sections.update_all(seller_id: new_seller.id)
    end

    # The origin seller's profile-level sections stay with them, but they must stop
    # referencing a product they no longer own: drop it from "products" sections and
    # delete any "featured product" section that featured it.
    def remove_from_origin_profile
      SellerProfileProductsSection.on_profile.where(seller_id: previous_seller.id).find_each do |section|
        next unless section.shown_products.include?(product.id)

        section.update!(shown_products: section.shown_products - [product.id])
      end

      SellerProfileFeaturedProductSection.on_profile.where(seller_id: previous_seller.id).find_each do |section|
        section.destroy! if section.featured_product_id == product.id
      end
    end

    def repoint_product
      product.user = new_seller
      product.save!
    end

    def leave_audit_comments
      previous_seller.comments.create!(
        author_id:,
        author_name:,
        comment_type: Comment::COMMENT_TYPE_NOTE,
        content: "Product \"#{product.name}\" (ID #{product.id}, /#{product.general_permalink}) transferred to " \
                 "#{seller_label(new_seller)}#{performed_by_suffix}.",
        idempotency_key: "product_transfer_out_#{product.id}_to_#{new_seller.id}"
      )

      new_seller.comments.create!(
        author_id:,
        author_name:,
        comment_type: Comment::COMMENT_TYPE_NOTE,
        content: "Product \"#{product.name}\" (ID #{product.id}, /#{product.general_permalink}) received from " \
                 "#{seller_label(previous_seller)}#{performed_by_suffix}.",
        idempotency_key: "product_transfer_in_#{product.id}_from_#{previous_seller.id}"
      )
    end

    def author_id
      performed_by&.id || GUMROAD_ADMIN_ID
    end

    def author_name
      performed_by&.name
    end

    def performed_by_suffix
      performed_by.present? ? " by #{seller_label(performed_by)}" : ""
    end

    def seller_label(user)
      "#{user.display_name} (ID #{user.id})"
    end

    # The product's row-level data (prices, variants, rich content, files, reviews,
    # co-purchase graph, etc.) is keyed on link_id and travels automatically. Changing the
    # owner already busts the product's caches through Link's after_update callback, so the
    # only derived data left to fix is its search document: the owner fields aren't in the
    # auto-reindexed set, so reindex it explicitly for the new seller.
    #
    # Audience members need no rebuild here: detaching the product's ProductAffiliates
    # already updated the origin seller's audience via callbacks, and the new seller
    # inherits no audience because purchases and followers stay with the origin (§6).
    # Likewise, ProductPageView analytics stay attributed to the origin seller.
    def rebuild_derived_data
      ProductIndexingService.perform(product:, action: "index", on_failure: :async)
    end
end
