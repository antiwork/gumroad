# frozen_string_literal: true

class Admin::Search::PurchasesService
  include ActiveModel::Validations

  attr_reader :search_attributes, :transaction_date, :formatted_transaction_date, :query, :product_title_query, :purchase_status, :creator_email, :license_key, :last_4, :card_type, :price, :expiry_date, :limit

  validate :validate_transaction_date_format

  def initialize(**search_params)
    @search_attributes = search_params
    @transaction_date = search_params[:transaction_date]

    @query = search_params[:query]
    @product_title_query = search_params[:product_title_query]
    @purchase_status = search_params[:purchase_status]
    @creator_email = search_params[:creator_email]
    @license_key = search_params[:license_key]
    @last_4 = search_params[:last_4]
    @card_type = search_params[:card_type]
    @price = search_params[:price]
    @expiry_date = search_params[:expiry_date]
    @limit = search_params[:limit]
  end

  def perform
    return Purchase.none unless valid?

    purchases = Purchase.order(created_at: :desc)

    if query.present?
      unions = [
        Gift.select("gifter_purchase_id as purchase_id").where(gifter_email: query).to_sql,
        Gift.select("giftee_purchase_id as purchase_id").where(giftee_email: query).to_sql,
        Purchase.select("purchases.id as purchase_id").where(email: query).to_sql,
        Purchase.select("purchases.id as purchase_id").where(card_visual: query, card_type: CardType::PAYPAL).to_sql,
        Purchase.select("purchases.id as purchase_id").where(stripe_fingerprint: query).to_sql,
        Purchase.select("purchases.id as purchase_id").where(ip_address: query).to_sql,
      ]

      union_sql = <<~SQL.squish
        SELECT purchase_id FROM (
          #{ unions.map { |u| "(#{u})" }.join(" UNION ") }
        ) via_gifts_and_purchases
      SQL
      purchases = purchases.where("purchases.id IN (#{union_sql})")

      # To be used only when query is set, as that uses an index to select purchases
      if product_title_query.present?
        raise ArgumentError, "product_title_query requires query parameter to be set" unless query.present?
        purchases = purchases.joins(:link).where("links.name LIKE ?", "%#{product_title_query}%")
      end

      if purchase_status.present?
        case purchase_status
        when "successful", "failed", "not_charged"
          purchases = purchases.where(purchase_state: purchase_status)
        when "chargeback"
          purchases = purchases.where.not(chargeback_date: nil)
            .where("purchases.flags & ? = 0", Purchase.flag_mapping["flags"][:chargeback_reversed])
        when "refunded"
          purchases = purchases.where(stripe_refunded: true)
        end
      end
    end

    if creator_email.present?
      user = User.find_by(email: creator_email)
      return Purchase.none unless user
      purchases = purchases.joins(:link).where(links: { user_id: user.id })
    end

    if license_key.present?
      license = License.find_by(serial: license_key)
      return Purchase.none unless license
      purchases = purchases.where(id: license.purchase_id)
    end

    if [transaction_date, last_4, card_type, price, expiry_date].any?
      purchases = purchases.where.not(stripe_fingerprint: nil)

      if transaction_date.present?
        start_date = (formatted_transaction_date - 1.day).beginning_of_day.to_fs(:db)
        end_date = (formatted_transaction_date + 1.day).end_of_day.to_fs(:db)
        purchases = purchases.where("created_at between ? and ?", start_date, end_date)
      end
      purchases = purchases.where(card_type:) if card_type.present?
      purchases = purchases.where(card_visual_sql_finder(last_4)) if last_4.present?
      purchases = purchases.where("price_cents between ? and ?", (price.to_d * 75).to_i, (price.to_d * 125).to_i) if price.present?
      if expiry_date.present?
        expiry_month, expiry_year = CreditCardUtility.extract_month_and_year(expiry_date)
        purchases = purchases.where(card_expiry_year: "20#{expiry_year}") if expiry_year.present?
        purchases = purchases.where(card_expiry_month: expiry_month) if expiry_month.present?
      end
    end

    purchases.limit(limit)
  end

  private
    def validate_transaction_date_format
      return if transaction_date.blank?
      @formatted_transaction_date = Date.strptime(transaction_date, "%Y-%m-%d").in_time_zone
    rescue ArgumentError
      errors.add(:transaction_date, "transaction_date must use YYYY-MM-DD format.")
    end
end
