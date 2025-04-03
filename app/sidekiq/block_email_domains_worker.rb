# frozen_string_literal: true

class BlockEmailDomainsWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(author_id, email_domains)
    email_domains.each do |email_domain|
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email_domain], email_domain, author_id)
    end
  end
end
