# frozen_string_literal: true

module SslCertificates
  class Base
    CONFIG_FILE = Rails.root.join("config", "ssl_certificates.yml.erb")
    SECRETS_S3_BUCKET = "gumroad-secrets"

    attr_reader :renew_in, :rate_limit, :acme_url, :sleep_duration, :rate_limit_hours,
                :account_email, :max_retries, :ssl_env, :invalid_domain_cache_expires_in

    def initialize
      load_config
    end

    def self.supported_environment?
      Rails.env.production? || (Rails.env.staging? && !ENV["BRANCH_DEPLOYMENT"])
    end

    def ssl_file_path(domain, filename)
      "custom-domains-ssl/#{ssl_env}/#{domain}/ssl/#{filename}"
    end

    private
      def certificate_authority
        LetsEncrypt
      end

      def log_message(domain, message)
        Rails.logger.info "[SSL Certificate Generator][#{domain}] #{message}"
      end

      def write_to_s3(key, content)
        obj = s3_client.bucket(SECRETS_S3_BUCKET).object(key)
        obj.put(body: content)
      end

      def delete_from_s3(key)
        s3_client.bucket(SECRETS_S3_BUCKET).object(key).delete
      end

      def s3_client
        @_s3_client ||= Aws::S3::Resource.new(credentials: Aws::InstanceProfileCredentials.new)
      end

      def convert_duration_to_seconds(duration)
        duration.seconds
      end

      def load_config
        config_erb = ERB.new(File.read(CONFIG_FILE)).result(binding)
        config = YAML.load(config_erb, aliases: true).fetch(Rails.env)

        @account_email                   = config["account_email"]
        @acme_url                        = config["acme_url"]
        @invalid_domain_cache_expires_in = convert_duration_to_seconds(config["invalid_domain_cache_expires_in"])
        @max_retries                     = config["max_retries"]
        @rate_limit                      = config["rate_limit"]
        @rate_limit_hours                = convert_duration_to_seconds(config["rate_limit_hours"])
        @renew_in                        = convert_duration_to_seconds(config["renew_in"])
        @sleep_duration                  = convert_duration_to_seconds(config["sleep_duration"])
        @ssl_env                         = config["ssl_env"]
      end
  end
end
