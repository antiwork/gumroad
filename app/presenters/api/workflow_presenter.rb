# frozen_string_literal: true

class Api::WorkflowPresenter
  CACHE_FILL_EXPIRATION = 1.minute

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
    payload[:emails] = email_props if include_emails
    payload
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

    def email_props
      open_counts = batched_open_counts
      click_counts = batched_click_counts

      emails.map do |email|
        sent_count = email.customer_count.to_i
        open_count = open_counts.fetch(email.id, 0)
        click_count = click_counts.fetch(email.id, 0)

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
          open_rate: rate(open_count, sent_count),
          click_count:,
          click_rate: rate(click_count, sent_count),
          created_at: email.created_at,
          updated_at: email.updated_at,
        }
      end
    end

    def batched_open_counts
      batched_counts(:unique_open_count) do |missing_ids|
        pipeline = [
          { "$match" => { "installment_id" => { "$in" => missing_ids } } },
          { "$group" => { "_id" => "$installment_id", "count" => { "$sum" => 1 } } },
        ]
        CreatorEmailOpenEvent.collection.aggregate(pipeline).each_with_object({}) do |row, counts|
          counts[row.fetch("_id").to_i] = row.fetch("count").to_i
        end
      end
    end

    def batched_click_counts
      batched_counts(:unique_click_count) do |missing_ids|
        CreatorEmailClickSummary
          .in(installment_id: missing_ids)
          .only(:installment_id, :total_unique_clicks)
          .each_with_object({}) do |summary, counts|
            counts[summary.installment_id] = summary.total_unique_clicks.to_i
          end
      end
    end

    def batched_counts(cache_key)
      keys_by_id = emails.to_h { |email| [email.id, email.key_for_cache(cache_key)] }
      cached_counts = Rails.cache.read_multi(*keys_by_id.values)
      counts = {}
      missing_ids = []

      keys_by_id.each do |id, key|
        if cached_counts.key?(key)
          counts[id] = cached_counts.fetch(key).to_i
        else
          missing_ids << id
        end
      end

      return counts if missing_ids.empty?

      queried_counts = missing_ids.index_with(0).merge(yield(missing_ids))
      queried_counts.each do |id, count|
        # A refresh can race this fill, so request-filled values must expire even if the refresh reads an older value.
        Rails.cache.write(keys_by_id.fetch(id), count, expires_in: CACHE_FILL_EXPIRATION, unless_exist: true)
      end
      counts.merge(queried_counts)
    end

    def rate(count, sent_count)
      return if sent_count.zero?

      (count.fdiv(sent_count) * 100).round(1)
    end
end
