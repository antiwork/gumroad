# frozen_string_literal: true

require "csv"

class Exports::AudienceExportService
  def initialize(user, options = {})
    @user = user
    @options = options
  end

  def perform
    CSV.generate do |csv|
      csv << ["Subscriber Email", "Subscribed Time"]

      query = @user.audience_members.select(:id, :email, :min_created_at)

      conditions = []
      conditions << "follower = true" if @options[:followers]
      conditions << "customer = true" if @options[:customers]
      conditions << "affiliate = true" if @options[:affiliates]

      query = query.where(conditions.join(" OR "))

      query.order(:min_created_at).each do |member|
        csv << [member.email, member.min_created_at]
      end
    end
  end

  private
    attr_reader :user, :options
end
