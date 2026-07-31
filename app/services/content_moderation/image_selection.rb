# frozen_string_literal: true

# Which images a moderation attempt looks at, and in what order.
#
# The order is deterministic in the URL, so re-validating unchanged content
# always moderates the same images in the same order: a seller cannot re-save a
# page (or an agent retry a publish) until a draw comes up that happens to omit
# the one prohibited image. Randomizing per attempt made that grind succeed
# eventually with probability approaching 1.
#
# It is also not document order, so images cannot simply be parked past a cap,
# and it is keyed on `secret_key_base` so which of a seller's own images a
# bounded caller looks at is not something they can compute and aim at.
#
# `bounded` is for callers that genuinely can only carry a few images (the
# prompt strategy's per-preset sample). Coverage of every image is
# ClassifierStrategy's job — it batches them, so bounding is not what keeps that
# affordable.
module ContentModeration::ImageSelection
  # Every URL, in the deterministic moderation order. The classifier walks this
  # (rather than taking a prefix) so an image OpenAI refuses to fetch falls
  # through to the next instead of costing a slot.
  def self.ordered(urls)
    urls.sort_by { |url| digest(url) }
  end

  # The first `limit` URLs of that order.
  def self.bounded(urls, limit)
    return urls if urls.size <= limit

    ordered(urls).first(limit)
  end

  def self.digest(url)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, url.to_s)
  end
  private_class_method :digest
end
