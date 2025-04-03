# frozen_string_literal: true

module Post::Caching
  def key_for_cache(key)
    "#{key}_for_installment_#{id}"
  end

  def invalidate_cache(key)
    Rails.cache.delete(key_for_cache(key))
  end
end
