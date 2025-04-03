# frozen_string_literal: true

Rails.application.config.after_initialize do
  cache_to_metric_keys = {
    ProfileSectionsPresenter::CACHE_KEY_PREFIX => "#{ProfileSectionsPresenter::CACHE_KEY_PREFIX}-metrics",
    ProductPresenter::ProductProps::SALES_COUNT_CACHE_KEY_REFIX => ProductPresenter::ProductProps::SALES_COUNT_CACHE_METRICS_KEY,
  }
  ActiveSupport::Notifications.subscribe "cache_read.active_support" do |event|
    cache_to_metric_keys.each do |key_prefix, metrics_key|
      if event.payload[:key].starts_with?(key_prefix)
        $redis.hincrby(metrics_key, event.payload[:hit] ? "hits" : "misses", 1)
        break
      end
    end
  end
end
