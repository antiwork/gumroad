# frozen_string_literal: true

class BalancesByProductService
  def initialize(user)
    @user = user
    @products = Link.for_balance_page(@user).select(:id, :name, :user_id).order(id: :desc).load
  end

  def process
    return [] if @products.empty?

    aggregations = PurchaseSearchService.search(search_options).aggregations
    product_buckets = aggregations.product_id_agg.buckets

    @products.map do |product|
      bucket = product_buckets.find { |product_bucket| product_bucket[:key] == product.id }
      next unless bucket # happens if product has no sales

      @for_seller = product.user_id == @user.id
      balance = {
        "link_id" => product.id,
        "name" => product.name,
        "gross" => 0,
        "fees" => 0,
        "taxes" => 0,
        "net" => 0,
        "refunds" => 0,
        "chargebacks" => 0,
      }

      paid_agg = bucket.not_chargedback_agg.not_fully_refunded_agg

      balance["gross"] = @for_seller ? bucket.dig(:price_cents_sum, :value).to_i : own_affiliate_cents(bucket, "amount")
      chargebacks_fee_returned = @for_seller ?
        bucket.chargedback_agg.dig(:fee_returned_cents_sum, :value).to_i :
        own_affiliate_cents(bucket.chargedback_agg, "fee")
      refunds_fee_returned = if @for_seller
        bucket.not_chargedback_agg.dig(:fee_refunded_cents_sum, :value).to_i
      else
        own_affiliate_cents(bucket.not_chargedback_agg, "fee_partially_refunded") +
        own_affiliate_cents(bucket.not_chargedback_agg.fully_refunded_agg, "fee")
      end
      balance["refunds"] = if @for_seller
        bucket.not_chargedback_agg.dig(:amount_refunded_cents_sum, :value).to_i
      else
        # affiliate revenue is already net of fees, so we need to add fees back to get gross refunds
        own_affiliate_cents(bucket.not_chargedback_agg, "amount_partially_refunded") +
        own_affiliate_cents(bucket.not_chargedback_agg.fully_refunded_agg, "amount") +
        refunds_fee_returned
      end
      balance["chargebacks"] = if @for_seller
        bucket.chargedback_agg.dig(:chargedback_cents_sum, :value).to_i
      else
        # affiliate revenue is already net of fees, so we need to add fees back to get gross chargebacks
        own_affiliate_cents(bucket.chargedback_agg, "amount") + chargebacks_fee_returned
      end

      gross_fees = @for_seller ? bucket.dig(:fee_cents_sum, :value).to_i : own_affiliate_cents(bucket, "fee")
      balance["fees"] = gross_fees - chargebacks_fee_returned - refunds_fee_returned

      balance["taxes"] = if @for_seller
        chargebacks_taxes_returned = bucket.chargedback_agg.dig(:tax_returned_cents_sum, :value).to_i
        full_refunds_taxes_returned = bucket.not_chargedback_agg.fully_refunded_agg.dig(:tax_refunded_cents_sum, :value).to_i
        partial_refunds_taxes_returned = paid_agg.dig(:tax_refunded_cents_sum, :value).to_i
        bucket.dig(:tax_cents_sum, :value).to_i - chargebacks_taxes_returned - full_refunds_taxes_returned - partial_refunds_taxes_returned
      else
        0
      end

      balance["gross"] += gross_fees unless @for_seller # affiliate revenue is already net of fees, so we need to add fees back to get gross revenue
      balance["net"] = balance["gross"] - balance["refunds"] - balance["chargebacks"] - balance["fees"] - balance["taxes"]
      balance
    end.compact
  end

  private
    def search_options
      {
        revenue_sharing_user: @user,
        # `revenue_sharing_user` also matches a purchase where @user is the direct affiliate on a collab
        # sale, which can be a product missing from `@products`; the agg returns one bucket per requested
        # product, so an off-page product would take a bucket and hide a row below.
        product: @products.map(&:id),
        state: "successful",
        price_greater_than: 0,
        exclude_bundle_product_purchases: true,
        size: 0,
        aggs: { product_id_agg: }
      }
    end

    def product_id_agg
      {
        terms: {
          field: "product_id",
          size: @products.size,
          order: { _key: "desc" }
        },
        aggs: {
          price_cents_sum: { sum: { field: "price_cents" } },
          fee_cents_sum: { sum: { field: "fee_cents" } },
          tax_cents_sum: { sum: { field: "tax_cents" } },
          **own_affiliate_credit_sums,
          chargedback_agg:,
          not_chargedback_agg:
        }
      }
    end

    def chargedback_agg
      {
        filter: { term: { not_chargedback_or_chargedback_reversed: false } },
        aggs: {
          chargedback_cents_sum: { sum: { field: "price_cents" } },
          fee_returned_cents_sum: { sum: { field: "fee_cents" } },
          tax_returned_cents_sum: { sum: { field: "tax_cents" } },
          **own_affiliate_credit_sums,
        }
      }
    end

    def not_chargedback_agg
      {
        filter: { term: { not_chargedback_or_chargedback_reversed: true } },
        aggs: {
          amount_refunded_cents_sum: { sum: { field: "amount_refunded_cents" } },
          fee_refunded_cents_sum: { sum: { field: "fee_refunded_cents" } },
          **own_affiliate_credit_sums(amount: "amount_partially_refunded", fee: "fee_partially_refunded"),
          fully_refunded_agg:,
          not_fully_refunded_agg:
        }
      }
    end

    def fully_refunded_agg
      {
        filter: { term: { stripe_refunded: true } },
        aggs: {
          amount_refunded_cents_sum: { sum: { field: "amount_refunded_cents" } },
          fee_refunded_cents_sum: { sum: { field: "fee_cents" } },
          tax_refunded_cents_sum: { sum: { field: "tax_cents" } },
          **own_affiliate_credit_sums,
        }
      }
    end

    def not_fully_refunded_agg
      {
        filter: { term: { stripe_refunded: false } },
        aggs: {
          tax_refunded_cents_sum: { sum: { field: "tax_refunded_cents" } }
        }
      }
    end

    # `@user` earns through one of a purchase's credits, and a collab purchase (:collab_and_affiliates)
    # credits a collaborator and a direct affiliate on the same sale, so a bucket can hold rows where
    # they are either. `revenue_sharing_user` matches all of them, hence one sum per credit, filtered
    # to `@user` — an unscoped sum would count the other affiliate's money as theirs.
    def own_affiliate_credit_sums(amount: "amount", fee: "fee")
      PurchaseSearchService::AFFILIATE_CREDIT_PREFIXES.flat_map do |prefix|
        [amount, fee].map do |measure|
          [:"#{prefix}_#{measure}_own", {
            filter: { term: { "#{prefix}_affiliate_user_id" => @user.id } },
            aggs: { total: { sum: { field: "#{prefix}_#{measure}_cents" } } },
          }]
        end
      end.to_h
    end

    def own_affiliate_cents(branch, measure)
      PurchaseSearchService::AFFILIATE_CREDIT_PREFIXES.sum do |prefix|
        branch.public_send(:"#{prefix}_#{measure}_own").total.value.to_i
      end
    end
end
