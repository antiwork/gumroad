# frozen_string_literal: true

class AdminSearchService
  class InvalidDateError < StandardError; end

  def search_purchases(query: nil, email: nil, product_title_query: nil, purchase_status: nil, creator_email: nil, license_key: nil, transaction_date: nil, last_4: nil, card_type: nil, price: nil, expiry_date: nil, limit: nil)
    purchases = Purchase.order(created_at: :desc)

    if email.present?
      purchases = purchases.where(email: email)
    end

    if query.present?
      unions = [
        Gift.select("gifter_purchase_id as purchase_id").where(gifter_email: query).to_sql,
        Gift.select("giftee_purchase_id as purchase_id").where(giftee_email: query).to_sql,
        Purchase.select("purchases.id as purchase_id").where(email: query).to_sql,
        Purchase.select("purchases.id as purchase_id").where(card_visual: query, card_type: CardType::PAYPAL).to_sql,
        Purchase.select("purchases.id as purchase_id").where(stripe_fingerprint: query).to_sql,
        Purchase.select("purchases.id as purchase_id").where(ip_address: query).to_sql,
      ]

      if (purchase_id = Purchase.from_external_id(query))
        unions << Purchase.select("purchases.id as purchase_id").where(id: purchase_id).to_sql
      end

      if !Purchase.external_id?(query)
        unions << Purchase.select("purchases.id as purchase_id").where(id: query.to_i).to_sql
      end

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
        when "successful"
          purchases = purchases.where(purchase_state: "successful")
        when "failed"
          purchases = purchases.where(purchase_state: "failed")
        when "not_charged"
          purchases = purchases.where(purchase_state: "not_charged")
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

    if [transaction_date, last_4, card_type, price, expiry_date].any?(&:present?)
      purchases = purchases.where.not(stripe_fingerprint: nil)

      if transaction_date.present?
        formatted_date = parse_date!(transaction_date)
        start_date = (formatted_date - 1.days).beginning_of_day.to_fs(:db)
        end_date = (formatted_date + 1.days).end_of_day.to_fs(:db)
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
    def parse_date!(transaction_date)
      Date.strptime(transaction_date, "%Y-%m-%d").in_time_zone
    rescue ArgumentError
      raise InvalidDateError, "transaction_date must use YYYY-MM-DD format."
    end

    def card_visual_sql_finder(last_4)
      [
        (["card_visual = ?"] * ChargeableVisual::LENGTH_TO_FORMAT.size).join(" OR "),
        *ChargeableVisual::LENGTH_TO_FORMAT.values.map { |visual_format| format(visual_format, last_4) }
      ]
    end
end
