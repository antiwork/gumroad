# frozen_string_literal: true

module AffiliateCookie
  include AffiliateQueryParams

  private
    def set_affiliate_cookie
      affiliate_id = fetch_affiliate_id(params)
      return unless affiliate_id.present?
      affiliate = Affiliate.find_by_external_id_numeric(affiliate_id)
      create_affiliate_id_cookie(affiliate) if affiliate.present?
    end

    def create_affiliate_id_cookie(affiliate)
      return unless affiliate.present?

      affiliate = affiliate.affiliate_user.direct_affiliate_accounts.where(seller: affiliate.seller).alive.last if !affiliate.global? && affiliate.deleted?
      return unless affiliate&.alive?

      logger.info("Setting affiliate cookie on guid #{cookies[:_gumroad_guid]} for affiliate id #{affiliate.external_id} from referrer #{request.referrer}")

      cookies[affiliate.cookie_key] = {
        value: Time.current.to_i,
        expires: affiliate.class.cookie_lifetime.from_now,
        httponly: true,
        domain: :all
      }
    end
end
