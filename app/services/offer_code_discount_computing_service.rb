# frozen_string_literal: true

class OfferCodeDiscountComputingService
  # While computing it rejects the product if quantity of the product is greater
  # than the quantity left for the offer_code for e.g. Suppose seller adds a
  # universal offer code which has 4 quantity left and a user adds three products
  # in bundle - A[2], B[3], C[1] (product names with quantity) and applies the
  # offer code. Then offer code will be applied on A[2], B[0], C[1]. It skipped B
  # because quantity of B was greater than the limit left for the offer_code.
  # Taking some more examples
  #   => A[2], B[3], C[2] --> A[2], C[2]
  #   => A[2], C[3]       --> A[2]

  attr_reader :code, :products

  def initialize(code, products)
    @code = code
    @products = products
  end

  def process
    return { error_code: :invalid_offer } unless code

    offer_code_quantity_left = {}
    offer_code_insufficient_quantity = {}
    products_data            = {}
    is_invalid_offer         = true
    is_inactive              = true

    products.each do |uid, product_info|
      product_quantity = product_info[:quantity].to_i
      link             = Link.fetch(product_info[:permalink])
      offer_code       = link&.find_offer_code(code:)

      next unless offer_code

      is_invalid_offer = false
      offer_code_quantity_left[offer_code.id] ||= offer_code.quantity_left if offer_code.max_purchase_count

      is_inactive = offer_code.inactive?

      offer_code_insufficient_quantity[offer_code.id] = !(product_quantity >= (offer_code.minimum_quantity || 0))

      if (offer_code.max_purchase_count.nil? || offer_code_quantity_left[offer_code.id] >= product_quantity) && !is_inactive && !offer_code_insufficient_quantity[offer_code.id]
        products_data[uid] = {
          discount: offer_code.discount,
        }
        offer_code_quantity_left[offer_code.id] -= product_quantity if offer_code.max_purchase_count
      end
    end

    if is_invalid_offer
      error_code = :invalid_offer
    elsif is_inactive
      error_code = :inactive
    elsif products_data.blank?
      if offer_code_insufficient_quantity.all? { |_id, invalid| invalid }
        error_code = :insufficient_quantity
      else
        error_code = offer_code_quantity_left.any? { |_key, quantity| quantity > 0 } ? :exceeding_quantity : :sold_out
      end
    end

    {
      products_data:,
      error_code:
    }
  end
end
