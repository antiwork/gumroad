# frozen_string_literal: true

class SubdomainRedirectorService
  CACHE_KEY = "subdomain_redirects_cache_key"
  private_constant :CACHE_KEY

  REDIS_KEY = "subdomain_redirects_config"
  private_constant :REDIS_KEY

  PROTECTED_HOSTS = VALID_API_REQUEST_HOSTS + VALID_REQUEST_HOSTS
  private_constant :PROTECTED_HOSTS

  def update(config)
    subdomain_redirect_namespace.set(REDIS_KEY, config)
    Rails.cache.delete(CACHE_KEY)
  end

  # Read on every request: an empty table is cached like any other, and a stalled Redis
  # read degrades to "no redirects" instead of failing the page.
  def redirects
    Rails.cache.fetch(CACHE_KEY) { parse_config(subdomain_redirect_namespace.get(REDIS_KEY)) }
  rescue *REDIS_TRANSPORT_ERRORS
    {}
  end

  def redirect_url_for(request)
    # Remove the trailing '/' from the host if the path is empty
    redirect_url = request.fullpath == "/" ? request.host : request.host + request.fullpath
    redirects[redirect_url]
  end

  def redirect_config_as_text
    redirects.map { |host, location| "#{host}=#{location}" }.join("\n")
  end

  private
    def parse_config(config)
      return {} if config.blank?

      config.split("\n").each_with_object({}) do |config_line, redirect_config|
        host, location = config_line.split("=", 2).map(&:strip)
        next if host.blank? || location.blank? || PROTECTED_HOSTS.include?(host)

        redirect_config[host.downcase] = location
      end
    end

    def subdomain_redirect_namespace
      @_subdomain_redirect_namespace ||= Redis::Namespace.new(:subdomain_redirect_namespace, redis: $redis)
    end
end
