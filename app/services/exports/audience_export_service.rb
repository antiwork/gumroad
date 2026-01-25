# frozen_string_literal: true

class Exports::AudienceExportService
  FIELDS = ["Subscriber Email", "Subscribed Time"].freeze

  def initialize(user, options = {})
    @user = user
    @options = options.with_indifferent_access
    timestamp = Time.current.to_fs(:db).gsub(/ |:/, "-")
    @filename = "Subscribers-#{@user.username}_#{timestamp}.csv"

    validate_options!
  end

  attr_reader :filename, :tempfile

  def perform
    @tempfile = Tempfile.new(["Subscribers", ".csv"], encoding: "UTF-8")

    CsvSafe.open(@tempfile, "wb", headers: FIELDS, write_headers: true) do |csv|
      query = build_query

      query.find_each do |member|
        csv << [member.email, member.min_created_at]
      end
    end

    @tempfile.rewind

    self
  end

  def build_query
    # NOTE: Build separate queries for each type to allow efficient index usage using UNION.
    queries = []
    queries << @user.audience_members.where(follower: true) if @options[:followers]
    queries << @user.audience_members.where(customer: true) if @options[:customers]
    queries << @user.audience_members.where(affiliate: true) if @options[:affiliates]

    return AudienceMember.none if queries.empty?

    union_sql = queries.map { |q| q.select(:id, :email, :min_created_at).to_sql }.join(" UNION ")

    # NOTE: Wrap in subquery to allow ordering.
    AudienceMember.from("(#{union_sql}) AS audience_members").order(:min_created_at)
  end


  private
    def validate_options!
      unless @options[:followers] || @options[:customers] || @options[:affiliates]
        raise ArgumentError, "At least one audience type (followers, customers, or affiliates) must be selected"
      end
    end
end
