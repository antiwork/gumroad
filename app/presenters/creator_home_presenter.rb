# frozen_string_literal: true

class CreatorHomePresenter
  include CurrencyHelper

  ACTIVITY_ITEMS_LIMIT = 10
  BALANCE_ITEMS_LIMIT = 3
  GUMHEAD_FEATURE = :gumhead
  # A fixed tag, because releases/latest here is a deploy release.
  GUMHEAD_DOWNLOAD_URL = "https://github.com/antiwork/gumroad/releases/download/gumhead-latest/Gumhead.dmg"

  attr_reader :pundit_user, :seller

  def initialize(pundit_user)
    @seller = pundit_user.seller
    @pundit_user = pundit_user
  end

  def creator_home_props
    has_sale = seller.sales.not_is_bundle_product_purchase.successful_or_preorder_authorization_successful.exists?

    first_product = seller.links.visible.exists?
    getting_started_dismissed = seller.has_dismissed_getting_started_checklist?

    getting_started_stats = if getting_started_dismissed
      { "first_product" => first_product }
    else
      {
        "customized_profile" => seller.name.present?,
        "first_follower" => seller.followers.exists?,
        "first_product" => first_product,
        "first_sale" => has_sale,
        "first_payout" => seller.has_payout_information?,
        "first_email" => seller.installments.not_workflow_installment.send_emails.exists?,
        "used_cli" => seller.has_used_cli?,
      }
    end

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

    sales = top_sales_data.map do |p|
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
    end.compact
    balances = UserBalanceStatsService.new(user: seller).fetch_overview

    stripe_verification_message = nil
    if seller.stripe_account.present?
      seller.user_compliance_info_requests.requested.each do |request|
        if request.verification_error_message.present?
          stripe_verification_message = request.verification_error_message
        end
      end
    end

    # Unconfirmed sellers can't publish, take payouts, or use the API. Surface
    # the resend path on the dashboard. Only the account owner gets the CTA
    # (same policy as Settings); team members see the notice without it.
    email_confirmation = nil
    if seller.has_unconfirmed_email?
      email_confirmation = {
        email: seller.unconfirmed_email.presence || seller.email,
        can_resend: Pundit.policy!(pundit_user, [:settings, :main, seller]).resend_confirmation_email?,
      }
    end

    tax_center_enabled = seller.tax_center_enabled?
    if tax_center_enabled
      tax_forms = []
      show_1099_download_notice = seller.user_tax_forms.for_year(Time.current.prev_year.year).exists?
    else
      # Limit to the last 4 tax years to avoid expensive per-year eligibility
      # queries that can cause request timeouts for long-lived accounts.
      max_tax_form_years = 4
      oldest_year = [seller.created_at.year, Time.current.year - max_tax_form_years + 1].max
      tax_forms = (Time.current.year.downto(oldest_year)).each_with_object({}) do |year, hash|
        url = seller.eligible_for_1099?(year) ? seller.tax_form_1099_download_url(year: year) : nil
        hash[year] = url if url.present?
      end
      show_1099_download_notice = tax_forms[Time.current.prev_year.year].present?
    end


    {
      name: seller.alive_user_compliance_info&.first_name || "",
      has_sale:,
      getting_started_stats:,
      getting_started_dismissed:,
      balances: {
        balance: formatted_dollar_amount(balances.fetch(:balance), with_currency: seller.should_be_shown_currencies_always?),
        last_seven_days_sales_total: formatted_dollar_amount(balances.fetch(:last_seven_days_sales_total), with_currency: seller.should_be_shown_currencies_always?),
        last_28_days_sales_total: formatted_dollar_amount(balances.fetch(:last_28_days_sales_total), with_currency: seller.should_be_shown_currencies_always?),
        total: formatted_dollar_amount(balances.fetch(:sales_cents_total), with_currency: seller.should_be_shown_currencies_always?),
      },
      sales:,
      activity_items:,
      stripe_verification_message:,
      email_confirmation:,
      tax_forms:,
      show_1099_download_notice:,
      tax_center_enabled:,
      **gumhead_props,
    }
  end

  private
    def gumhead_props
      return {} unless Feature.active?(GUMHEAD_FEATURE, seller)
      return {} if seller.has_dismissed_gumhead_promo?

      { gumhead: { download_url: GUMHEAD_DOWNLOAD_URL } }
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
