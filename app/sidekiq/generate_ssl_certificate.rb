# frozen_string_literal: true

class GenerateSslCertificate
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  # #488: surface silently-stuck SSL renewals. Once retries are exhausted the
  # ACME order has failed and `ssl_certificate_issued_at` stays NULL with no
  # other signal — report it so a stuck domain is caught without a support
  # ticket (one such domain was down over HTTPS for ~4 months unnoticed).
  sidekiq_retries_exhausted do |msg, exception|
    custom_domain_id = msg["args"].first
    domain = CustomDomain.find_by(id: custom_domain_id)&.domain
    ErrorNotifier.notify(
      "GenerateSslCertificate exhausted retries — SSL certificate not provisioned (ssl_certificate_issued_at remains unset)",
      custom_domain_id:,
      domain:,
      exception_class: exception&.class&.name,
      exception_message: exception&.message
    )
  end

  def perform(id)
    if SslCertificates::Generate.supported_environment?
      custom_domain = CustomDomain.find(id)
      return if custom_domain.deleted? # The domain was deleted after this job was enqueued

      SslCertificates::Generate.new(custom_domain).process
    end
  end
end
