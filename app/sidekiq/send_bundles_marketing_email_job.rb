# frozen_string_literal: true

class SendBundlesMarketingEmailJob
  MINIMUM_PRODUCTS_PER_BUNDLE = 2
  LAST_YEAR = 1.year.ago.year

  def perform
    User.not_suspended
        .where(deleted_at: nil)
        .joins(:payments)
        .merge(Payment.completed.where(created_at: 1.year.ago..))
        .select("users.id, users.currency_type")
        .distinct
        .find_in_batches do |group|
      ReplicaLagWatcher.watch
      group.each do |user|
        user_id = user.id
        currency_type = user.currency_type

        options = {
          user_id:,
          sort: ProductSortKey::FEATURED,
          is_alive_on_profile: true,
          is_subscription: false,
          is_bundle: false,
        }

        best_selling_products = Link.search(Link.search_options(options.merge({ sort: ProductSortKey::HOT_AND_NEW })))
                                    .records.records
                                    .filter { _1.price_currency_type == currency_type }
                                    .take(5)

        everything_products = Link.search(Link.search_options(options))
                                  .records.records
                                  .filter { _1.price_currency_type == currency_type }

        year_products = everything_products.filter { _1.created_at.year == LAST_YEAR }

        bundles = []

        bundles << bundle_props(Product::BundlesMarketing::BEST_SELLING_BUNDLE, best_selling_products) if best_selling_products.size >= MINIMUM_PRODUCTS_PER_BUNDLE
        bundles << bundle_props(Product::BundlesMarketing::EVERYTHING_BUNDLE, everything_products) if everything_products.size >= MINIMUM_PRODUCTS_PER_BUNDLE
        bundles << bundle_props(Product::BundlesMarketing::YEAR_BUNDLE, year_products) if year_products.size >= MINIMUM_PRODUCTS_PER_BUNDLE

        CreatorMailer.bundles_marketing(seller_id: user_id, bundles:).deliver_later if bundles.any?
      end
    end
  end

  private
    DISCOUNT_FACTOR = 0.8

    def bundle_props(type, products)
      price = products.sum(&:display_price_cents)

      {
        type:,
        price:,
        discounted_price: price * DISCOUNT_FACTOR,
        products: products.map { { id: _1.external_id, name: _1.name, url: _1.long_url } }
      }
    end
end
