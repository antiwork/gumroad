# frozen_string_literal: true

class InstallmentEvent < ApplicationRecord
  belongs_to :event, optional: true
  belongs_to :installment, optional: true

  after_commit :update_installment_events_cache_count, on: [:create, :destroy]

  private
    def update_installment_events_cache_count
      UpdateInstallmentEventsCountCacheWorker.perform_in(2.seconds, installment_id)
    end
end
