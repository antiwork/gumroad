# frozen_string_literal: true

class CustomDomainVerificationService
  RESOLVER_TIMEOUT_IN_SECONDS = 5
  SSL_CERT_CHECK_CACHE_EXPIRY = 10.days

  attr_reader :domain

  def initialize(domain:)
    @domain = domain
    @dns_resolver = Resolv::DNS.new

    dns_resolver.timeouts = RESOLVER_TIMEOUT_IN_SECONDS
  end

  def process
    points_to_gumroad?
  rescue => e
    Rails.logger.error e.full_message

    false
  end

  def points_to_gumroad?
    @_does_point_to_gumroad ||= domains_pointed_to_gumroad.any?
  end

  def domains_pointed_to_gumroad
    pointed_domains = []

    parsed_host = PublicSuffix.parse(domain)

    if parsed_host.trd.nil? || parsed_host.trd == CustomDomain::WWW_PREFIX
      parsed_domain_with_www_prefix = "#{CustomDomain::WWW_PREFIX}.#{parsed_host.domain}"

      pointed_domains << parsed_host.domain if cname_or_alias_configured?(parsed_host.domain)
      pointed_domains << parsed_domain_with_www_prefix if cname_or_alias_configured?(parsed_domain_with_www_prefix)
    else
      pointed_domains << domain if cname_or_alias_configured?(domain)
    end

    pointed_domains
  end

  def has_valid_ssl_certificates?
    domains_pointed_to_gumroad.all? do |domain|
      ssl_cert_check_redis_namespace.get(ssl_cert_check_cache_key(domain)) || has_valid_ssl_certificate?(domain)
    end
  end

  private
    attr_reader :dns_resolver

    def has_valid_ssl_certificate?(domain)
      @ssl_service ||= SslCertificates::Base.new
      ssl_cert_s3_key = @ssl_service.ssl_file_path(domain, "cert")

      @s3 ||= Aws::S3::Resource.new(credentials: Aws::InstanceProfileCredentials.new)
      cert_obj = @s3.bucket(SslCertificates::Base::SECRETS_S3_BUCKET).object(ssl_cert_s3_key)

      cert = cert_obj.exists? && cert_obj.get.body.read
      valid = OpenSSL::X509::Certificate.new(cert).not_after > Time.current if cert.present?

      # Cache only when the certificate is valid
      ssl_cert_check_redis_namespace.set(ssl_cert_check_cache_key(domain), valid, ex: SSL_CERT_CHECK_CACHE_EXPIRY) if valid

      valid
    end

    def cname_or_alias_configured?(domain_variant)
      cname_is_setup_correctly?(domain_variant) || alias_is_setup_correctly?(domain_variant)
    rescue => e
      Rails.logger.info("CNAME/ALIAS check error for custom domain '#{domain}'. Error: #{e.inspect}")
      false
    end

    def cname_is_setup_correctly?(domain_variant)
      # Example:
      #
      # > domain = "production-sample-shop.gumroad.com"
      # > Resolv::DNS.new.getresources(domain, Resolv::DNS::Resource::IN::CNAME).first.name.to_s
      # => "domains.gumroad.com"
      #
      # We would verify this against the domain stored in CUSTOM_DOMAIN_CNAME to check if the domain
      # is setup correctly.

      current_domain_cname = dns_resolver.getresources(domain_variant, Resolv::DNS::Resource::IN::CNAME)
      !current_domain_cname.empty? && current_domain_cname.first.name.to_s == CUSTOM_DOMAIN_CNAME
    end

    def alias_is_setup_correctly?(domain_variant)
      alias_records_correctly_configured?(CUSTOM_DOMAIN_CNAME, domain_variant) || alias_records_correctly_configured?(CUSTOM_DOMAIN_STATIC_IP_HOST, domain_variant)
    end

    def alias_records_correctly_configured?(target_domain, seller_domain)
      # Example:
      #
      # > domain = "production-sample-shop.gumroad.com"
      # > Resolv::DNS.new.getresources(domain, Resolv::DNS::Resource::IN::A).map { |record| record.address.to_s }
      # => ["50.19.197.177", "3.214.103.12", "54.164.66.117"]
      # > Resolv::DNS.new.getresources(CUSTOM_DOMAIN_CNAME, Resolv::DNS::Resource::IN::A).map { |record| record.address.to_s }
      # => ["50.19.197.177", "3.214.103.12", "54.164.66.117"]
      #
      # When the sorted list of IPs match, we can confirm alias is setup correctly.

      current_domain_addresses = dns_resolver.getresources(seller_domain, Resolv::DNS::Resource::IN::A).map { |record| record.address.to_s }
      custom_domain_addresses = dns_resolver.getresources(target_domain, Resolv::DNS::Resource::IN::A).map { |record| record.address.to_s }
      current_domain_addresses.sort == custom_domain_addresses.sort
    end

    def ssl_cert_check_redis_namespace
      @_ssl_cert_check_redis_namespace ||= Redis::Namespace.new(:ssl_cert_check_namespace, redis: $redis)
    end

    def ssl_cert_check_cache_key(domain)
      "ssl_cert_check:#{domain}"
    end
end
