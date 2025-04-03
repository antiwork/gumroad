# frozen_string_literal: true

class PurchasingPowerParityService
  def get_factor(country_code, seller)
    factor = if country_code.present?
      (ppp_namespace.get(country_code).presence || 1).to_f
    else
      1.0
    end
    [factor, seller.min_ppp_factor].max
  end

  def set_factor(country_code, factor)
    ppp_namespace.set(country_code, factor.to_s)
  end

  def get_all_countries_factors(seller)
    country_codes = Compliance::Countries.mapping.keys
    country_codes.zip(ppp_namespace.mget(country_codes)).to_h.transform_values do |value|
      [(value.presence || 1).to_f, seller.min_ppp_factor].max
    end
  end

 private
   def ppp_namespace
     @_ppp_namespace ||= Redis::Namespace.new(:ppp, redis: $redis)
   end
end
