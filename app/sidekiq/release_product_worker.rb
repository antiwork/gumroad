# frozen_string_literal: true

class ReleaseProductWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :critical

  def perform(link_id)
    Link.find(link_id).preorder_link.release!
  end
end
