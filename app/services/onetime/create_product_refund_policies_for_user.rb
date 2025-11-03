# frozen_string_literal: true

class Onetime::CreateProductRefundPoliciesForUser
  attr_reader :user_id, :max_refund_period_in_days, :results

  def initialize(user_id:, max_refund_period_in_days: 0)
    @user_id = user_id
    @max_refund_period_in_days = max_refund_period_in_days
    @results = { success: [], errors: [] }
  end

  def process
    user = User.find(user_id)

    Rails.logger.info("Creating refund policies for user #{user_id} with max_refund_period_in_days: #{max_refund_period_in_days}")

    products_without_policy = user.products.where.missing(:product_refund_policy)
    total_count = products_without_policy.count

    Rails.logger.info("Found #{total_count} products without refund policies")

    products_without_policy.find_each do |product|
      refund_policy = product.create_product_refund_policy!(
        seller: user,
        max_refund_period_in_days:
      )

      success_message = "✓ Created refund policy for product #{product.id}: #{product.name}. Policy: #{refund_policy.title}"
      Rails.logger.info(success_message)

      results[:success] << {
        product_id: product.id,
        product_name: product.name,
        policy_title: refund_policy.title
      }
    rescue StandardError => e
      error_message = "✗ Error creating refund policy for product #{product.id}: #{product.name} - #{e.message}"
      Rails.logger.error(error_message)

      results[:errors] << {
        product_id: product.id,
        product_name: product.name,
        error: e.message
      }
    end

    log_summary
    results
  end

  private
    def log_summary
      Rails.logger.info("=" * 60)
      Rails.logger.info("Summary for user #{user_id}:")
      Rails.logger.info("Successfully created #{results[:success].count} refund policies")
      Rails.logger.info("Failed to create #{results[:errors].count} refund policies")
      Rails.logger.info("=" * 60)
    end
end
