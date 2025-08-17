# frozen_string_literal: true

module Purchase::RiskAssessment
  extend ActiveSupport::Concern

  RISK_SCORE_THRESHOLDS = {
    low: 0.3,
    medium: 0.6,
    high: 0.8
  }.freeze

  def calculate_risk_score
    return 0.0 if is_test_purchase?

    score = 0.0
    score += email_risk_score
    score += ip_risk_score
    score += payment_method_risk_score
    score += behavioral_risk_score

    [score, 1.0].min
  end

  def risk_level
    score = calculate_risk_score

    case score
    when 0..RISK_SCORE_THRESHOLDS[:low]
      :low
    when RISK_SCORE_THRESHOLDS[:low]..RISK_SCORE_THRESHOLDS[:medium]
      :medium
    when RISK_SCORE_THRESHOLDS[:medium]..RISK_SCORE_THRESHOLDS[:high]
      :high
    else
      :critical
    end
  end

  def requires_manual_review?
    risk_level.in?([:high, :critical]) || flagged_for_review?
  end

  def flagged_for_review?
    suspicious_email? || suspicious_payment_pattern? || high_velocity_purchases?
  end

  private

  def email_risk_score
    return 0.3 if disposable_email?
    return 0.2 if new_email_domain?
    return 0.4 if blocked_email_patterns?

    0.0
  end

  def ip_risk_score
    return 0.5 if proxy_or_vpn_ip?
    return 0.3 if high_risk_country?
    return 0.2 if suspicious_ip_pattern?

    0.0
  end

  def payment_method_risk_score
    return 0.4 if prepaid_card?
    return 0.3 if card_country_mismatch?
    return 0.2 if new_payment_method?

    0.0
  end

  def behavioral_risk_score
    score = 0.0
    score += 0.3 if rapid_successive_purchases?
    score += 0.2 if unusual_purchase_pattern?
    score += 0.1 if first_time_buyer?

    score
  end

  def disposable_email?
    DisposableEmailChecker.disposable?(email)
  end

  def new_email_domain?
    domain = email.split('@').last
    EmailDomainAnalyzer.new_domain?(domain)
  end

  def blocked_email_patterns?
    BlockedEmailPattern.matches?(email)
  end

  def proxy_or_vpn_ip?
    IpAnalyzer.proxy_or_vpn?(ip_address)
  end

  def high_risk_country?
    HighRiskCountry.include?(ip_country)
  end

  def suspicious_ip_pattern?
    IpAnalyzer.suspicious_pattern?(ip_address)
  end

  def prepaid_card?
    credit_card&.prepaid?
  end

  def card_country_mismatch?
    return false unless credit_card&.country.present?

    credit_card.country != ip_country
  end

  def new_payment_method?
    credit_card&.created_at&.> 1.hour.ago
  end

  def rapid_successive_purchases?
    Purchase.where(email: email)
            .where('created_at > ?', 10.minutes.ago)
            .count > 3
  end

  def unusual_purchase_pattern?
    recent_purchases = Purchase.where(email: email)
                              .where('created_at > ?', 24.hours.ago)

    recent_purchases.count > 10 ||
    recent_purchases.sum(:price_cents) > 50000
  end

  def first_time_buyer?
    Purchase.where(email: email).successful.count == 0
  end
end
