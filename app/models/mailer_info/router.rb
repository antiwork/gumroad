# frozen_string_literal: true

module MailerInfo::Router
  extend self

  include Kernel
  def determine_email_provider(domain)
    raise ArgumentError, "Invalid domain: #{domain}" unless MailerInfo::DeliveryMethod::DOMAINS.include?(domain)

    return MailerInfo::EMAIL_PROVIDER_SENDGRID if Feature.inactive?(:resend)
    return MailerInfo::EMAIL_PROVIDER_RESEND if Feature.active?(:force_resend)

    # If counters are not set, both return 0, which would default to SendGrid
    current_count = get_current_count(domain)
    max_count = get_max_count(domain)
    Rails.logger.info("[Router] #{domain}: count=#{current_count}/#{max_count}")

    return MailerInfo::EMAIL_PROVIDER_SENDGRID if max_count_reached?(domain)

    rand_val = Kernel.rand
    prob = get_probability(domain)
    Rails.logger.info("[Router] #{domain}: rand=#{rand_val}, prob=#{prob}")

    if rand_val <= prob
      $redis.incr(current_count_key(domain))
      MailerInfo::EMAIL_PROVIDER_RESEND
    else
      MailerInfo::EMAIL_PROVIDER_SENDGRID
    end
  end

  def set_probability(domain, date, probability)
    raise ArgumentError, "Invalid domain: #{domain}" unless MailerInfo::DeliveryMethod::DOMAINS.include?(domain)

    $redis.set(probability_key(domain, date: date.to_date), probability, ex: 3.months)
  end

  def set_max_count(domain, date, count)
    raise ArgumentError, "Invalid domain: #{domain}" unless MailerInfo::DeliveryMethod::DOMAINS.include?(domain)

    $redis.set(max_count_key(domain, date: date.to_date), count, ex: 3.months)
  end

  # Easily readable stats for a domain
  def domain_stats(domain)
    raise ArgumentError, "Invalid domain: #{domain}" unless MailerInfo::DeliveryMethod::DOMAINS.include?(domain)

    stats = []
    # Rough range of dates to get stats for, around the time when the migration happened
    1.month.ago.to_date.step(1.month.from_now.to_date) do |date|
      probability = get_probability(domain, date:, allow_nil: true)
      max_count = get_max_count(domain, date:, allow_nil: true)
      current_count = get_current_count(domain, date:, allow_nil: true)
      # Ignore dates where the counters are not set
      next if probability.nil? && max_count.nil? && current_count.nil?

      stats << {
        date: date.to_s,
        probability:,
        max_count:,
        current_count:,
      }
    end
    stats
  end

  def stats
    MailerInfo::DeliveryMethod::DOMAINS.to_h { [_1, domain_stats(_1)] }
  end

  private
    def get_probability(domain, date: today, allow_nil: false)
      val = $redis.get(probability_key(domain, date:))
      allow_nil && val.nil? ? nil : val.to_f
    end

    def get_max_count(domain, date: today, allow_nil: false)
      val = $redis.get(max_count_key(domain, date:))
      allow_nil && val.nil? ? nil : val.to_i
    end

    def get_current_count(domain, date: today, allow_nil: false)
      val = $redis.get(current_count_key(domain, date:))
      allow_nil && val.nil? ? nil : val.to_i
    end

    def max_count_reached?(domain, date: today)
      max_count = get_max_count(domain, date:)
      current_count = get_current_count(domain, date:)

      current_count >= max_count
    end

    def today
      Date.current.to_s
    end

    def current_count_key(domain, date: today)
      "mail_router:counter:#{domain}:#{date}"
    end

    def max_count_key(domain, date: today)
      "mail_router:max_count:#{domain}:#{date}"
    end

    def probability_key(domain, date: today)
      "mail_router:probability:#{domain}:#{date}"
    end
end
