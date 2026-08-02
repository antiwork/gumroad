# frozen_string_literal: true

# Which images a moderation attempt looks at, and in what order.
#
# Deterministic in the URL so re-validating unchanged content always moderates
# the same images: a seller cannot re-save a page until a draw comes up that
# omits the one prohibited image, which a per-attempt shuffle let them grind out
# with probability approaching 1. Not document order either, so images cannot be
# parked past a cap, and keyed on `secret_key_base` so which images a bounded
# caller looks at is not something a seller can compute and aim at.
module ContentModeration::ImageSelection
  # Every URL, in the deterministic moderation order.
  def self.ordered(urls)
    urls.sort_by { |url| digest(url) }
  end

  # The first `limit` URLs of that order. For callers that genuinely can only
  # carry a few images (PromptStrategy's per-preset sample); full coverage is
  # ClassifierStrategy's job.
  def self.bounded(urls, limit)
    return urls if urls.size <= limit

    ordered(urls).first(limit)
  end

  def self.digest(url)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, url.to_s)
  end
  private_class_method :digest
end
