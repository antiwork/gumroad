# frozen_string_literal: true

# Map of origin prefixes to determine if a url is hosted at a location fronted by a CDN.
# Use cdn_url_for in ProductsHelper to get the CDN url for a url on an origin contained in the map.
# Should not be used to replace the use of asset_host. Should only be used for converting URLs persisted
# and referencing files stored at an origin, that are fronted by a CDN.

CDN_URL_MAP = {
  # regex/string of origin url => replacement text
}

# We use several S3 buckets to host user uploaded content. That content is proxied by the hosts below.
public_assets_cdn_hosts = {
  development: {
    s3_proxy_host: "https://staging-static-2.gumroad.com",
    public_storage_host: "https://staging-public-files.gumroad.com"
  },
  test: {
    s3_proxy_host: "https://test-static-2.gumroad.com",
    public_storage_host: "https://test-public-files.gumroad.com"
  },
  staging: {
    s3_proxy_host: "https://staging-static-2.gumroad.com",
    public_storage_host: "https://staging-public-files.gumroad.com"
  },
  production: {
    s3_proxy_host: "https://static-2.gumroad.com",
    public_storage_host: "https://public-files.gumroad.com"
  }
}

CDN_S3_PROXY_HOST = public_assets_cdn_hosts.dig(Rails.env.to_sym, :s3_proxy_host)
PUBLIC_STORAGE_CDN_S3_PROXY_HOST = public_assets_cdn_hosts.dig(Rails.env.to_sym, :public_storage_host)

if CDN_S3_PROXY_HOST && PUBLIC_STORAGE_CDN_S3_PROXY_HOST
  if Rails.env.production?
    # Optimize CDN_URL_MAP for production to reduce the number of string look ups.
    CDN_URL_MAP["#{AWS_S3_ENDPOINT}/gumroad/"] = "#{CDN_S3_PROXY_HOST}/res/gumroad/"
    CDN_URL_MAP["https://gumroad-public-storage.s3.amazonaws.com/"] = "#{PUBLIC_STORAGE_CDN_S3_PROXY_HOST}/"
  else
    CDN_URL_MAP.merge!("#{AWS_S3_ENDPOINT}/gumroad/" => "#{CDN_S3_PROXY_HOST}/res/gumroad/",
                       "#{AWS_S3_ENDPOINT}/gumroad-staging/" => "#{CDN_S3_PROXY_HOST}/res/gumroad-staging/",
                       "#{AWS_S3_ENDPOINT}/gumroad_dev/" => "#{CDN_S3_PROXY_HOST}/res/gumroad_dev/",
                       "https://gumroad-dev-public-storage.s3.amazonaws.com/" => "#{PUBLIC_STORAGE_CDN_S3_PROXY_HOST}/")
  end
end
