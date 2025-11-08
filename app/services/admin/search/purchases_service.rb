# frozen_string_literal: true

class Admin::Search::PurchasesService
  attr_reader :card_type, :creator_email, :expiry_date, :last_4, :license_key, :price, :product_title_query, :purchase_status, :query, :transaction_date

  def initialize(**search_params)
    @card_type = search_params[:card_type]
    @creator_email = search_params[:creator_email]
    @expiry_date = search_params[:expiry_date]
    @last_4 = search_params[:last_4]
    @license_key = search_params[:license_key]
    @price = search_params[:price]
    @product_title_query = search_params[:product_title_query]
    @purchase_status = search_params[:purchase_status]
    @query = search_params[:query]
    @transaction_date = search_params[:transaction_date]
  end

  def perform
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
        begin
          formatted_date = Date.strptime(transaction_date.to_s.strip, "%Y-%m-%d").in_time_zone
          start_date = (formatted_date - 1.day).beginning_of_day.to_fs(:db)
          end_date = (formatted_date + 1.day).end_of_day.to_fs(:db)
          purchases = purchases.where("created_at between ? and ?", start_date, end_date)
        rescue ArgumentError
          raise ArgumentError, "transaction_date must use YYYY-MM-DD format."
        end
      end
      purchases = purchases.where(card_type:) if card_type.present?
      if last_4.present?
        purchases = purchases.where(
          (["card_visual = ?"] * ChargeableVisual::LENGTH_TO_FORMAT.size).join(" OR "),
          *ChargeableVisual::LENGTH_TO_FORMAT.values.map { |visual_format| format(visual_format, last_4) }
        )
      end
      purchases = purchases.where("price_cents between ? and ?", (price.to_d * 75).to_i, (price.to_d * 125).to_i) if price.present?
      if expiry_date.present?
        expiry_month, expiry_year = CreditCardUtility.extract_month_and_year(expiry_date)
        purchases = purchases.where(card_expiry_year: "20#{expiry_year}") if expiry_year.present?
        purchases = purchases.where(card_expiry_month: expiry_month) if expiry_month.present?
      end
    end

    purchases
  end
end
