# frozen_string_literal: true

class CreatorAnalytics::Web
  def initialize(user:)
    @user = user
  end

  def by_date(dates:)
    views_data = product_page_views(dates).by_product_and_date
    sales_data = sales(dates).by_product_and_date
    result = result_metadata(dates)
    result[:by_date] = { views: {}, sales: {}, totals: {} }

    %i[views sales totals].each do |type|
      product_permalinks.each do |product_id, product_permalink|
        result[:by_date][type][product_permalink] = dates_strings(dates).map do |date|
          case type
          when :views then views_data[[product_id, date]]
          when :sales then sales_data.dig([product_id, date], :count)
          when :totals then sales_data.dig([product_id, date], :total)
          end || 0
        end
      end
    end

    result
  end

  def by_state(dates:)
    views_data = product_page_views(dates).by_product_and_country_and_state
    sales_data = sales(dates).by_product_and_country_and_state
    result = { by_state: { views: {}, sales: {}, totals: {} } }
    usa = "United States"

    %i[views sales totals].each do |type|
      product_permalinks.each do |product_id, product_permalink|
        result[:by_state][type][product_permalink] = { usa => [0] * STATES_SUPPORTED_BY_ANALYTICS.size }
      end
    end

    views_data.each do |(product_id, country, state), count|
      product_permalink = product_permalinks[product_id]
      if country == usa
        state_index = STATES_SUPPORTED_BY_ANALYTICS.index(state)
        state_index = STATES_SUPPORTED_BY_ANALYTICS.index(STATE_OTHER) if state_index.blank?
        result[:by_state][:views][product_permalink][country][state_index] += count
      else
        result[:by_state][:views][product_permalink][country] ||= 0
        result[:by_state][:views][product_permalink][country] += count
      end
    end

    sales_data.each do |(product_id, country, state), values|
      product_permalink = product_permalinks[product_id]
      if country == usa
        state_index = STATES_SUPPORTED_BY_ANALYTICS.index(state)
        state_index = STATES_SUPPORTED_BY_ANALYTICS.index(STATE_OTHER) if state_index.blank?
        result[:by_state][:sales][product_permalink][country][state_index] += values[:count]
        result[:by_state][:totals][product_permalink][country][state_index] += values[:total]
      else
        result[:by_state][:sales][product_permalink][country] ||= 0
        result[:by_state][:sales][product_permalink][country] += values[:count]
        result[:by_state][:totals][product_permalink][country] ||= 0
        result[:by_state][:totals][product_permalink][country] += values[:total]
      end
    end

    result
  end

  def by_referral(dates:)
    views_data = product_page_views(dates).by_product_and_referrer_and_date
    sales_data = sales(dates).by_product_and_referrer_and_date
    result = result_metadata(dates)
    result[:by_referral] = { views: {}, sales: {}, totals: {} }

    views_data.each do |(product_id, referrer, date), count|
      product_permalink = product_permalinks[product_id]
      referrer_name = referrer_domain_to_name(referrer)
      result[:by_referral][:views][product_permalink] ||= {}
      result[:by_referral][:views][product_permalink][referrer_name] ||= [0] * dates_strings(dates).size
      result[:by_referral][:views][product_permalink][referrer_name][dates_strings(dates).index(date)] = count
    end

    sales_data.each do |(product_id, referrer, date), values|
      product_permalink = product_permalinks[product_id]
      referrer_name = referrer_domain_to_name(referrer)
      result[:by_referral][:sales][product_permalink] ||= {}
      result[:by_referral][:sales][product_permalink][referrer_name] ||= [0] * dates_strings(dates).size
      result[:by_referral][:sales][product_permalink][referrer_name][dates_strings(dates).index(date)] = values[:count]
      result[:by_referral][:totals][product_permalink] ||= {}
      result[:by_referral][:totals][product_permalink][referrer_name] ||= [0] * dates_strings(dates).size
      result[:by_referral][:totals][product_permalink][referrer_name][dates_strings(dates).index(date)] = values[:total]
    end

    result
  end

  private
    def result_metadata(dates)
      metadata = {
        dates_and_months: D3.date_month_domain(dates),
        start_date: D3.formatted_date(dates.first),
        end_date: D3.formatted_date(dates.last),
      }
      first_sale_created_at = @user.first_sale_created_at_for_analytics
      metadata[:first_sale_date] = D3.formatted_date_with_timezone(first_sale_created_at, @user.timezone) if first_sale_created_at
      metadata
    end

    def product_page_views(dates)
      CreatorAnalytics::ProductPageViews.new(user: @user, products:, dates:)
    end

    def sales(dates)
      CreatorAnalytics::Sales.new(user: @user, products:, dates:)
    end

    def products
      @user.products_for_creator_analytics.load
    end

    def product_permalinks
      @_product_id_to_permalink ||= products.to_h { |product| [product.id, product.unique_permalink] }
    end

    def dates_strings(dates)
      dates.map(&:to_s)
    end

    def referrer_domain_to_name(referrer_domain)
      return "direct" if referrer_domain.blank?
      return "Recommended by Gumroad" if referrer_domain == REFERRER_DOMAIN_FOR_GUMROAD_RECOMMENDED_PRODUCTS

      COMMON_REFERRERS_NAMES[referrer_domain] || referrer_domain
    end
end
