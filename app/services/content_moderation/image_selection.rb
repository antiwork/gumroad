# frozen_string_literal: true

# Which images a moderation attempt looks at when the content carries more than
# the budget allows.
#
# The order is deterministic in the URL, so re-validating unchanged content
# always moderates the same images: a seller cannot re-save a page (or an agent
# retry a publish) until a subset comes up that happens to omit the one
# prohibited image. Randomizing per attempt made that grind succeed eventually
# with probability approaching 1, which is a worse failure than a bounded subset.
#
# It is also not document order, so the images cannot simply be parked past a
# fixed cutoff, and it is keyed on `secret_key_base` so which of a seller's own
# images fall inside the budget is not something they can compute and aim at.
module ContentModeration::ImageSelection
  # Every URL, in the deterministic moderation order. Callers that can retry an
  # individual image (the classifier drops ones OpenAI refuses to fetch) walk
  # this and stop once they have enough, so a rejected image falls through to the
  # next one instead of costing a slot.
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
