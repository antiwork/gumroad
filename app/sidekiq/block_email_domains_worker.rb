# frozen_string_literal: true

class BlockEmailDomainsWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(author_id, email_domains)
    email_domains.each do |email_domain|
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email_domain], object_value: email_domain, by: author_id)
    end
  end
end
