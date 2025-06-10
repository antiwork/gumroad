# frozen_string_literal: true

class ResetAdminActionCallCountsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform
    Rails.application.eager_load!

    AdminActionCallInfo.transaction do
      AdminActionCallInfo.destroy_all
      Admin::BaseController.descendants.each do |controller_class|
        controller_class.public_instance_methods(false).each do |action_name|
          AdminActionCallInfo.create!(controller_name: controller_class.name, action_name:)
        end
      end
    end
  end
end
