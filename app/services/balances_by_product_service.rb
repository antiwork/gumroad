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

      balance["gross"] = bucket.dig(agg_key("price_cents_sum"), :value).to_i
      chargebacks_fee_returned = bucket.chargedback_agg.dig(agg_key("fee_returned_cents_sum"), :value).to_i
      refunds_fee_returned = if @for_seller
        bucket.not_chargedback_agg.dig(:fee_refunded_cents_sum, :value).to_i
      else
        bucket.not_chargedback_agg.dig(:affiliate_fee_refunded_cents_sum, :value).to_i +
        bucket.not_chargedback_agg.fully_refunded_agg.dig(:affiliate_fee_refunded_cents_sum, :value).to_i
      end
      balance["refunds"] = if @for_seller
        bucket.not_chargedback_agg.dig(:amount_refunded_cents_sum, :value).to_i
      else
        # affiliate revenue is already net of fees, so we need to add fees back to get gross refunds
        bucket.not_chargedback_agg.dig(:affiliate_amount_refunded_cents_sum, :value).to_i +
        bucket.not_chargedback_agg.fully_refunded_agg.dig(:affiliate_amount_refunded_cents_sum, :value).to_i +
        refunds_fee_returned
      end
      balance["chargebacks"] = if @for_seller
        bucket.chargedback_agg.dig(:chargedback_cents_sum, :value).to_i
      else
        # affiliate revenue is already net of fees, so we need to add fees back to get gross chargebacks
        bucket.chargedback_agg.dig(:affiliate_chargedback_cents_sum, :value).to_i + chargebacks_fee_returned
      end

      gross_fees = bucket.dig(agg_key("fee_cents_sum"), :value).to_i
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
          affiliate_price_cents_sum: { sum: { field: "affiliate_credit_amount_cents" } },
          affiliate_fee_cents_sum: { sum: { field: "affiliate_credit_fee_cents" } },
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
          affiliate_chargedback_cents_sum: { sum: { field: "affiliate_credit_amount_cents" } },
          affiliate_fee_returned_cents_sum: { sum: { field: "affiliate_credit_fee_cents" } },
        }
      }
    end

    def not_chargedback_agg
      {
        filter: { term: { not_chargedback_or_chargedback_reversed: true } },
        aggs: {
          amount_refunded_cents_sum: { sum: { field: "amount_refunded_cents" } },
          fee_refunded_cents_sum: { sum: { field: "fee_refunded_cents" } },
          affiliate_amount_refunded_cents_sum: { sum: { field: "affiliate_credit_amount_partially_refunded_cents" } },
          affiliate_fee_refunded_cents_sum: { sum: { field: "affiliate_credit_fee_partially_refunded_cents" } },
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
          affiliate_amount_refunded_cents_sum: { sum: { field: "affiliate_credit_amount_cents" } },
          affiliate_fee_refunded_cents_sum: { sum: { field: "affiliate_credit_fee_cents" } },
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

    def agg_key(key)
      :"#{@for_seller ? "" : "affiliate_"}#{key}"
    end
end
