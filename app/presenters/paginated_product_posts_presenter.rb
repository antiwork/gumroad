# frozen_string_literal: true

class PaginatedProductPostsPresenter
  include Pagy::Backend

  PER_PAGE = 10
  private_constant :PER_PAGE

  def initialize(product:, variant_external_id:, options: {})
    @product = product
    @variant_external_id = variant_external_id
    @options = options
    @page = [options[:page].to_i, 1].max
  end

  def index_props
    posts = Installment.receivable_by_customers_of_product(product:, variant_external_id:)
    pagination, paginated_posts = pagy_array(posts, limit: PER_PAGE, page:)

    {
      total: pagination.count,
      next_page: pagination.next,
      posts: paginated_posts.map do |post|
        date = if post.workflow_id.present? && post.installment_rule.present?
          { type: "workflow_email_rule", time_duration: post.installment_rule.displayable_time_duration, time_period: post.installment_rule.time_period }
        else
          { type: "date", value: post.published_at }
        end

        { id: post.external_id, name: post.name, date:, url: post.full_url }
      end
    }
  end

  private
    attr_reader :product, :variant_external_id, :options, :page
end
