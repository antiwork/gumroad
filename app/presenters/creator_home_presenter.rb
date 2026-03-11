# frozen_string_literal: true

class CreatorHomePresenter
  include CurrencyHelper

  ACTIVITY_ITEMS_LIMIT = 10
  BALANCE_ITEMS_LIMIT = 3

  attr_reader :pundit_user, :seller

  def initialize(pundit_user)
    @seller = pundit_user.seller
    @pundit_user = pundit_user
  end

  def inertia_props
    {
      name: seller.alive_user_compliance_info&.first_name || "",
      has_sale: has_sale?,
      getting_started_stats: getting_started_stats,
      stripe_verification_message: stripe_verification_message,
      tax_forms: tax_data[:tax_forms],
      show_1099_download_notice: tax_data[:show_1099_download_notice],
      tax_center_enabled: Feature.active?(:tax_center, seller),
      dashboard_data: InertiaRails.defer(group: "dashboard") { dashboard_data },
    }
  end

  def dashboard_data
    {
      balances: formatted_balances,
      sales: top_sales,
      activity_items: activity_items,
    }
  end

  private
    def has_sale?
      seller.sales.not_is_bundle_product_purchase.successful_or_preorder_authorization_successful.exists?
    end

    def getting_started_stats
      {
        "customized_profile" => seller.name.present?,
        "first_follower" => seller.followers.exists?,
        "first_product" => seller.links.visible.exists?,
        "first_sale" => has_sale?,
        "first_payout" => seller.has_payout_information?,
        "first_email" => seller.installments.not_workflow_installment.send_emails.exists?,
        "purchased_small_bets" => seller.purchased_small_bets?,
      }
    end

    def formatted_balances
      balances = UserBalanceStatsService.new(user: seller).fetch[:overview]
      show_currency = seller.should_be_shown_currencies_always?
      {
        balance: formatted_dollar_amount(balances.fetch(:balance), with_currency: show_currency),
        last_seven_days_sales_total: formatted_dollar_amount(balances.fetch(:last_seven_days_sales_total), with_currency: show_currency),
        last_28_days_sales_total: formatted_dollar_amount(balances.fetch(:last_28_days_sales_total), with_currency: show_currency),
        total: formatted_dollar_amount(balances.fetch(:sales_cents_total), with_currency: show_currency),
      }
    end

    def top_sales
      today = Time.now.in_time_zone(seller.timezone).to_date
      analytics = CreatorAnalytics::CachingProxy.new(seller).data_for_dates(today - 30, today)
      top_sales_data = analytics[:by_date][:sales]
        .sort_by { |_, sales| -sales&.sum }.take(BALANCE_ITEMS_LIMIT)

      product_permalinks = top_sales_data.map(&:first)
      products_by_permalink = seller.products
        .where(unique_permalink: product_permalinks)
        .includes(thumbnail_alive: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } })
        .select(&:alive?)
        .index_by(&:unique_permalink)

      top_sales_data.filter_map do |p|
        product = products_by_permalink[p[0]]
        next unless product

        {
          "id" => product.unique_permalink,
          "name" => product.name,
          "thumbnail" => product.thumbnail_alive&.url,
          "sales" => product.successful_sales_count,
          "revenue" => product.total_usd_cents,
          "visits" => product.number_of_views,
          "today" => analytics[:by_date][:totals][product.unique_permalink]&.last || 0,
          "last_7" => analytics[:by_date][:totals][product.unique_permalink]&.last(7)&.sum || 0,
          "last_30" => analytics[:by_date][:totals][product.unique_permalink]&.sum || 0,
        }
      end
    end

    def stripe_verification_message
      return nil unless seller.stripe_account.present?

      seller.user_compliance_info_requests.requested.each do |request|
        return request.verification_error_message if request.verification_error_message.present?
      end
      nil
    end

    def tax_data
      @tax_data ||= begin
        tax_center_enabled = Feature.active?(:tax_center, seller)
        if tax_center_enabled
          {
            tax_forms: [],
            show_1099_download_notice: seller.user_tax_forms.for_year(Time.current.prev_year.year).exists?,
          }
        else
          tax_forms = (Time.current.year.downto(seller.created_at.year)).each_with_object({}) do |year, hash|
            url = seller.eligible_for_1099?(year) ? seller.tax_form_1099_download_url(year: year) : nil
            hash[year] = url if url.present?
          end
          {
            tax_forms:,
            show_1099_download_notice: tax_forms[Time.current.prev_year.year].present?,
          }
        end
      end
    end

    def activity_items
      items = followers_activity_items + sales_activity_items
      items.sort_by { |item| item["timestamp"] }.last(ACTIVITY_ITEMS_LIMIT).reverse
    end

    def sales_activity_items
      sales = seller.sales.successful.not_is_bundle_product_purchase.includes(:link).order(created_at: :desc).limit(ACTIVITY_ITEMS_LIMIT).load
      sales.map do |sale|
        {
          "type" => "new_sale",
          "timestamp" => sale.created_at.iso8601,
          "details" => {
            "price_cents" => sale.price_cents,
            "email" => sale.email,
            "full_name" => sale.full_name,
            "product_name" => sale.link.name,
            "product_unique_permalink" => sale.link.unique_permalink,
          }
        }
      end
    end

    def followers_activity_items
      results = ConfirmedFollowerEvent.search(
        query: { bool: { filter: [{ term: { followed_user_id: seller.id } }] } },
        sort: [{ timestamp: { order: :desc } }],
        size: ACTIVITY_ITEMS_LIMIT,
        _source: [:name, :email, :timestamp, :follower_user_id],
      ).map { |result| result["_source"] }

      followers_user_ids = results.map { |result| result["follower_user_id"] }.compact.uniq
      followers_users_by_id = User.where(id: followers_user_ids).select(:id, :name, :timezone).index_by(&:id)

      results.map do |result|
        follower_user = followers_users_by_id[result["follower_user_id"]]
        {
          "type" => "follower_#{result["name"]}",
          "timestamp" => result["timestamp"],
          "details" => {
            "email" => result["email"],
            "name" => follower_user&.name,
          }
        }
      end
    end
end
