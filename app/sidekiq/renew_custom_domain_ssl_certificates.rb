# frozen_string_literal: true

class RenewCustomDomainSslCertificates
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :low

  def perform
    if SslCertificates::Renew.supported_environment?
      SslCertificates::Renew.new.process
    end
  end
end
