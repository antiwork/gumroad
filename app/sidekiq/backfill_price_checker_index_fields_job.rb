# frozen_string_literal: true

class BackfillPriceCheckerIndexFieldsJob
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :low, lock: :until_executed

  def perform
    Onetime::BackfillPriceCheckerIndexFields.process
  end
end
