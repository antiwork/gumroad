# frozen_string_literal: true

class Iffy::Post::IngestJob
  include Sidekiq::Job
  sidekiq_options queue: :long, retry: 3

  def perform(post_id)
    post = Installment.find(post_id)

    Iffy::Post::IngestService.new(post).perform
  end
end
