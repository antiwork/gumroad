# frozen_string_literal: true

class SocialProofVariableSubstitutionService
  def initialize(widget:, context: {})
    @widget = widget
    @context = context
  end

  def substitute_variables(text)
    return text if text.blank?

    content = text.dup
    substitutions.each { |key, value| content.gsub!(key, value.to_s) }
    content
  end

  def processed_widget_data
    {
      title: substitute_variables(@widget.title),
      description: substitute_variables(@widget.description),
      cta_text: substitute_variables(@widget.cta_text)
    }
  end

  private

  def substitutions
    @substitutions ||= {
      "{total_sales}" => total_sales,
      "{recent_sales}" => recent_sales,
      "{customer}" => customer_name,
      "{product}" => product_name,
      "{price}" => product_price,
      "{country}" => customer_country
    }
  end

  def total_sales
    if @widget.universal?
      # For universal widgets, sum across all seller's products
      @widget.user.links.visible.sum(&:successful_sales_count)
    elsif @widget.links.any?
      # For product-specific widgets, sum across associated products
      @widget.links.sum(&:successful_sales_count)
    elsif product
      # Fallback to single product if available
      product.successful_sales_count
    else
      # No product context available
      0
    end
  end

  def recent_sales
    # Get sales from last 7 days
    search_options = {
      created_after: 7.days.ago,
      size: 0,
      track_total_hits: true
    }

    if @widget.universal?
      products = @widget.user.links.visible
      search_options[:product] = products
    elsif @widget.links.any?
      search_options[:product] = @widget.links
    elsif product
      search_options[:product] = product
    else
      return 0
    end

    PurchaseSearchService.search(
      Purchase::ACTIVE_SALES_SEARCH_OPTIONS.merge(search_options)
    ).results.total
  end

  def customer_name
    # This would come from recent purchase data or be anonymized
    @context[:customer_name] || recent_customer_name || "someone"
  end

  def product_name
    if product
      product.name
    elsif @widget.links.any?
      @widget.links.first.name
    else
      "this product"
    end
  end

  def product_price
    target_product = product || @widget.links.first
    return "$0" unless target_product
    return "$0" unless target_product.price_currency_type.present?

    Money.new(target_product.price_cents, target_product.price_currency_type).format
  end

  def customer_country
    @context[:customer_country] || recent_customer_country || "somewhere"
  end

  def product
    # Get product from context (preferred) or fallback to widget's first associated product
    @product ||= @context[:product]
  end

  def recent_customer_name
    return nil unless product

    # Get a recent customer name (anonymized for privacy)
    recent_purchase = recent_purchases.first
    return nil unless recent_purchase

    # Return first name only for privacy
    recent_purchase.full_name&.split&.first || "someone"
  end

  def recent_customer_country
    return nil unless product

    recent_purchase = recent_purchases.first
    recent_purchase&.country_or_from_ip_address
  end

  def recent_purchases
    @recent_purchases ||= begin
      if @widget.universal?
        products = @widget.user.links.visible
      elsif @widget.links.any?
        products = @widget.links
      elsif product
        products = [product]
      else
        return Purchase.none
      end

      Purchase.joins(:link)
               .where(link: products)
               .merge(Purchase.successful)
               .where('purchases.created_at > ?', 30.days.ago)
               .order('purchases.created_at DESC')
               .limit(10)
    end
  end
end
