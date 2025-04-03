# frozen_string_literal: true

CLOUDFLARE_CACHE_LIMIT = GlobalConfig.get("CLOUDFLARE_CACHE_LIMIT", 8_000_000_000).to_i # 8GB
