# frozen_string_literal: true

class Admin::Search::ServiceChargesService < Admin::Search::BaseService
  attr_reader :query, :creator_email, :last_4, :card_type, :price, :expiry_date, :limit

  def initialize(**search_params)
    super(**search_params)

    @query = search_params[:query]
    @creator_email = search_params[:creator_email]
    @last_4 = search_params[:last_4]
    @card_type = search_params[:card_type]
    @price = search_params[:price]
    @expiry_date = search_params[:expiry_date]
    @limit = search_params[:limit]
  end

  def perform
    return ServiceCharge.none unless valid?
    super
  end

  protected
    def search
      service_charges = ServiceCharge.order(created_at: :desc)

      if query.present?
        service_charges = service_charges.joins(:user).where(users: { email: query })
      end

      if creator_email.present?
        user = User.find_by(email: creator_email)
        return ServiceCharge.none unless user
        service_charges = service_charges.where(user_id: user.id)
      end

      if [transaction_date, last_4, card_type, price, expiry_date].any?
        service_charges = service_charges.where.not(charge_processor_fingerprint: nil)

        if transaction_date.present?
          start_date = (formatted_transaction_date - 1.day).beginning_of_day.to_fs(:db)
          end_date = (formatted_transaction_date + 1.day).end_of_day.to_fs(:db)
          service_charges = service_charges.where("created_at between ? and ?", start_date, end_date)
        end

        service_charges = service_charges.where(card_type:) if card_type.present?
        service_charges = service_charges.where(card_visual_sql_finder(last_4)) if last_4.present?
        service_charges = service_charges.where("charge_cents between ? and ?", (price.to_d * 75).to_i, (price.to_d * 125).to_i) if price.present?

        if expiry_date.present?
          expiry_month, expiry_year = CreditCardUtility.extract_month_and_year(expiry_date)
          service_charges = service_charges.where(card_expiry_year: "20#{expiry_year}") if expiry_year.present?
          service_charges = service_charges.where(card_expiry_month: expiry_month) if expiry_month.present?
        end
      end

      service_charges.limit(limit)
    end
end
