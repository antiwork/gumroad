# frozen_string_literal: true

class Api::WorkflowPresenter
  API_CACHE_EXPIRATION = 5.seconds
  API_CACHE_PREFIX = "api_workflow"

  def initialize(workflow:, include_emails: false, emails_count: nil)
    @workflow = workflow
    @include_emails = include_emails
    @emails_count = emails_count
  end

  def props
    payload = {
      id: workflow.external_id,
      name: workflow.name,
      audience_type: workflow.workflow_type,
      trigger: workflow.workflow_trigger,
      product_id: workflow.link&.external_id,
      variant_id: workflow.base_variant&.external_id,
      state: workflow.published_at.present? ? Installment::PUBLISHED : Installment::DRAFT,
      published_at: workflow.published_at,
      first_published_at: workflow.first_published_at,
      send_to_past_customers: workflow.send_to_past_customers?,
      emails_count: emails_count || emails.size,
      filters: workflow.json_filters.except(:workflow_trigger),
      created_at: workflow.created_at,
      updated_at: workflow.updated_at,
    }
    payload[:emails] = present_emails(emails) if include_emails
    payload
  end

  def email_props(email, include_analytics: true)
    present_emails([email], include_analytics:).sole
  end

  private
    attr_reader :workflow, :include_emails, :emails_count

    def emails
      @emails ||= workflow.installments
        .alive
        .joins(:installment_rule)
        .includes(:installment_rule)
        .order("installment_rules.delayed_delivery_time ASC", "installments.id ASC")
        .to_a
    end

    def present_emails(emails, include_analytics: true)
      open_counts = include_analytics ? batched_open_counts(emails) : {}
      click_counts = include_analytics ? batched_click_counts(emails) : {}

      emails.map do |email|
        sent_count = email.customer_count.to_i
        open_count = open_counts.fetch(email.id, nil)
        click_count = click_counts.fetch(email.id, nil)

        {
          id: email.external_id,
          subject: email.name,
          message: email.message,
          audience_type: email.installment_type,
          product_id: workflow.link&.external_id,
          state: email.display_type,
          published_at: email.published_at,
          send_emails: email.send_emails?,
          delay: {
            amount: email.installment_rule.displayable_time_duration,
            unit: email.installment_rule.time_period,
          },
          sent_count:,
          open_count:,
          open_rate: open_count.nil? ? nil : rate(open_count, sent_count),
          click_count:,
          click_rate: click_count.nil? ? nil : rate(click_count, sent_count),
          created_at: email.created_at,
          updated_at: email.updated_at,
        }
      end
    end

    def batched_open_counts(emails)
      batched_counts(emails, :unique_open_count) do |missing_ids|
        pipeline = [
          { "$match" => { "installment_id" => { "$in" => missing_ids } } },
          { "$group" => { "_id" => "$installment_id", "count" => { "$sum" => 1 } } },
        ]
        CreatorEmailOpenEvent.collection.aggregate(pipeline).each_with_object({}) do |row, counts|
          counts[row.fetch("_id").to_i] = row.fetch("count").to_i
        end
      end
    end

    def batched_click_counts(emails)
      batched_counts(emails, :unique_click_count) do |missing_ids|
        CreatorEmailClickSummary
          .in(installment_id: missing_ids)
          .only(:installment_id, :total_unique_clicks)
          .each_with_object({}) do |summary, counts|
            counts[summary.installment_id] = summary.total_unique_clicks.to_i
          end
      end
    end

    def batched_counts(emails, cache_key)
      keys_by_id = emails.to_h do |email|
        event_key = email.key_for_cache(cache_key)
        [email.id, { event: event_key, api: "#{API_CACHE_PREFIX}_#{event_key}" }]
      end
      cached_counts = Rails.cache.read_multi(*keys_by_id.values.flat_map(&:values))
      counts = {}
      missing_ids = []

      keys_by_id.each do |id, keys|
        if cached_counts.key?(keys.fetch(:event))
          counts[id] = cached_counts.fetch(keys.fetch(:event)).to_i
        elsif cached_counts.key?(keys.fetch(:api))
          counts[id] = cached_counts.fetch(keys.fetch(:api)).to_i
        else
          missing_ids << id
        end
      end

      return counts if missing_ids.empty?

      queried_counts = missing_ids.index_with(0).merge(yield(missing_ids))
      api_counts = queried_counts.transform_keys { |id| keys_by_id.fetch(id).fetch(:api) }
      Rails.cache.write_multi(api_counts, expires_in: API_CACHE_EXPIRATION)
      counts.merge(queried_counts)
    end

    def rate(count, sent_count)
      return if sent_count.zero?

      (count.fdiv(sent_count) * 100).round(1)
    end
end
