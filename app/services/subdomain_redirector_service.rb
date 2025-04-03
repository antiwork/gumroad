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

  def redirects
    Rails.cache.fetch(CACHE_KEY) do
      config = subdomain_redirect_namespace.get(REDIS_KEY)
      return {} if config.blank?

      redirect_config = {}

      config.split("\n").each do |config_line|
        host, location = config_line.split("=", 2).map(&:strip)

        if host.present? && location.present?
          redirect_config[host.downcase] = location unless PROTECTED_HOSTS.include?(host)
        end
      end

      redirect_config
    end
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
    def subdomain_redirect_namespace
      @_subdomain_redirect_namespace ||= Redis::Namespace.new(:subdomain_redirect_namespace, redis: $redis)
    end
end
