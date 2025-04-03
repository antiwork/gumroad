# frozen_string_literal: true

class GenerateSslCertificate
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(id)
    if SslCertificates::Generate.supported_environment?
      custom_domain = CustomDomain.find(id)
      return if custom_domain.deleted? # The domain was deleted after this job was enqueued

      SslCertificates::Generate.new(custom_domain).process
    end
  end
end
