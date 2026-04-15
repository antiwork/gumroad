# frozen_string_literal: true

module SslCertificates
  class LetsEncrypt < Base
    CHALLENGE_TTL = 1.hour.to_i

    attr_reader :domain, :certificate_private_key

    def initialize(domain)
      super()

      @domain = domain
      @certificate_private_key = OpenSSL::PKey::RSA.new(2048)
    end

    def process
      order, http_challenge = order_certificate
      prepare_http_challenge(http_challenge)
      request_validation(http_challenge)

      poll_validation_status(http_challenge)

      begin
        certificate = finalize_with_csr(order, http_challenge)
        upload_certificate_to_s3(certificate, certificate_private_key)
      rescue => e
        log_message(domain, "SSL Certificate cannot be issued. Error: #{e.message}")
        return false
      ensure
        delete_http_challenge(http_challenge)
      end

      true
    end

      private
        def upload_certificate_to_s3(certificate, certificate_private_key)
          cert_path = ssl_file_path(domain, "cert")
          write_to_s3(cert_path, certificate.to_s)

          private_key_path = ssl_file_path(domain, "key")
          write_to_s3(private_key_path, certificate_private_key.to_s)
        end

        def finalize_with_csr(order, http_challenge)
          csr = Acme::Client::CertificateRequest.new(private_key: certificate_private_key,
                                                     subject: { common_name: domain })
          order.finalize(csr:)

          max_retries.times do
            break unless order.status == "processing"
            sleep(sleep_duration)
            http_challenge.reload
          end

          order.certificate
        end

        def poll_validation_status(http_challenge)
          max_retries.times do
            break unless http_challenge.status == "pending"
            sleep(sleep_duration)
            http_challenge.reload
          end
        end

        def request_validation(http_challenge)
          http_challenge.request_validation
        end

        def prepare_http_challenge(http_challenge)
          token = http_challenge.token
          file_content = http_challenge.file_content
          $redis.setex(RedisKey.acme_challenge(token), CHALLENGE_TTL, file_content)
        end

        def delete_http_challenge(http_challenge)
          token = http_challenge.token
          $redis.del(RedisKey.acme_challenge(token))
        end

        def order_certificate
          order = client.new_order(identifiers: [domain])
          authorization = order.authorizations.first
          [order, authorization.http]
        end

        def client
          client = Acme::Client.new(private_key: account_private_key, directory: acme_url)

          begin
            cache_key = Digest::SHA256.hexdigest("#{account_private_key}-#{acme_url}")
            Rails.cache.fetch("acme_account_status_#{cache_key}") { client.account.present? }
          rescue Acme::Client::Error::AccountDoesNotExist
            Rails.logger.info "Creating new ACME account - #{account_email}"
            client.new_account(contact: "mailto:#{account_email}", terms_of_service_agreed: true)
          end

          client
        end

        def account_private_key
          OpenSSL::PKey::RSA.new(ENV["LETS_ENCRYPT_ACCOUNT_PRIVATE_KEY"])
        end
  end
end
