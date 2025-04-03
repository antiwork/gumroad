# frozen_string_literal: true

require "csv"

class Exports::AudienceExportService
  def initialize(user)
    @user = user
  end

  def perform
    CSV.generate do |csv|
      csv << ["Follower Email", "Followed Time"]

      @user.followers.active.find_each do |follower|
        csv << [follower.email, follower.created_at]
      end
    end
  end
end
