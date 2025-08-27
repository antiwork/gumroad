# frozen_string_literal: true

class Api::Internal::Helper::PurchasesController < Api::Internal::Helper::BaseController
  before_action :authorize_helper_token!
  before_action :fetch_last_purchase, only: [:refund_last_purchase, :resend_last_receipt]

  REFUND_LAST_PURCHASE_OPENAPI = {
    summary: "Refund last purchase",
    description: "Refund last purchase based on the customer email, should be used when within product refund policy",
    requestBody: {
      required: true,
      content: {
        'application/json': {
          schema: {
            type: "object",
            properties: {
              email: { type: "string", description: "Email address of the customer" }
            },
            required: ["email"]
          }
        }
      }
    },
    security: [{ bearer: [] }],
    responses: {
      '200': {
        description: "Successfully refunded purchase",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: true },
                message: { type: "string" }
              }
            }
          }
        }
      },
      '422': {
        description: "Purchase not found or not refundable",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                message: { type: "string" }
              }
            }
          }
        }
      }
    }
  }.freeze
  def refund_last_purchase
    if @purchase.present? && @purchase.refund_and_save!(GUMROAD_ADMIN_ID)
      render json: { success: true, message: "Successfully refunded purchase number #{@purchase.external_id_numeric}" }
    else
      render json: { success: false, message: @purchase.present? ? @purchase.errors.full_messages.to_sentence : "Purchase not found" }, status: :unprocessable_entity
    end
  end

  RESEND_LAST_RECEIPT_OPENAPI = {
    summary: "Resend receipt",
    description: "Resend last receipt to customer",
    requestBody: {
      required: true,
      content: {
        'application/json': {
          schema: {
            type: "object",
            properties: {
              email: { type: "string", description: "Email address of the customer" }
            },
            required: ["email"]
          }
        }
      }
    },
    security: [{ bearer: [] }],
    responses: {
      '200': {
        description: "Successfully resent receipt",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: true },
                message: { type: "string" }
              }
            }
          }
        },
      },
      '422': {
        description: "Purchase not found",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                message: { type: "string" }
              }
            }
          }
        }
      },
    }
  }.freeze
  def resend_last_receipt
    @purchase.resend_receipt
    render json: { success: true, message: "Successfully resent receipt for purchase number #{@purchase.external_id_numeric}" }
  end

  RESEND_ALL_RECEIPTS_OPENAPI = {
    summary: "Resend all receipts",
    description: "Resend all receipt emails to customer for all their purchases",
    requestBody: {
      required: true,
      content: {
        'application/json': {
          schema: {
            type: "object",
            properties: {
              email: { type: "string", description: "Email address of the customer" }
            },
            required: ["email"]
          }
        }
      }
    },
    security: [{ bearer: [] }],
    responses: {
      '200': {
        description: "Successfully resent all receipts",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: true },
                message: { type: "string" },
                count: { type: "integer" }
              }
            }
          }
        },
      },
      '404': {
        description: "No purchases found for email",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                message: { type: "string" }
              }
            }
          }
        }
      },
    }
  }.freeze
  def resend_all_receipts
    purchases = Purchase.where(email: params[:email]).successful
    return render json: { success: false, message: "No purchases found for email: #{params[:email]}" }, status: :not_found if purchases.empty?

    CustomerMailer.grouped_receipt(purchases.ids).deliver_later(queue: "critical")
    render json: {
      success: true,
      message: "Successfully resent all receipts to #{params[:email]}",
      count: purchases.count
    }
  end

  SEARCH_PURCHASE_OPENAPI = {
    summary: "Search purchase",
    description: "Search purchase by email, seller, license key, or card details. At least one of the parameters is required.",
    requestBody: {
      required: true,
      content: {
        'application/json': {
          schema: {
            type: "object",
            properties: {
              email: { type: "string", description: "Email address of the customer/buyer" },
              creator_email: { type: "string", description: "Email address of the creator/seller" },
              license_key: { type: "string", description: "Product license key (4 groups of alphanumeric characters separated by dashes)" },
              charge_amount: { type: "number", description: "Charge amount in dollars" },
              purchase_date: { type: "string", description: "Purchase date in YYYY-MM-DD format" },
              card_type: { type: "string", description: "Card type" },
              card_last4: { type: "string", description: "Last 4 digits of the card" }
            },
          }
        }
      }
    },
    security: [{ bearer: [] }],
    responses: {
      '200': {
        description: "Purchase found",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: true },
                message: { const: "Purchase found" },
                purchase: {
                  type: "object",
                  properties: {
                    id: { type: "integer" },
                    email: { type: "string" },
                    link_name: { type: "string" },
                    price_cents: { type: "integer" },
                    purchase_state: { type: "string" },
                    created_at: { type: "string", format: "date-time" },
                    receipt_url: { type: "string", format: "uri" },
                    seller_email: { type: "string", description: "Email address of the product seller" }
                  }
                }
              }
            }
          }
        }
      },
      '404': {
        description: "Purchase not found",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                message: { const: "Purchase not found" }
              }
            }
          }
        }
      },
      '400': {
        description: "Invalid date format",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                message: { const: "purchase_date must use YYYY-MM-DD format." }
              }
            }
          }
        }
      }
    }
  }.freeze
  def search
    search_params = {
      query: params[:email],
      creator_email: params[:creator_email],
      license_key: params[:license_key],
      transaction_date: params[:purchase_date],
      price: params[:charge_amount].present? ? params[:charge_amount].to_f : nil,
      card_type: params[:card_type],
      last_4: params[:card_last4],
    }
    return render json: { success: false, message: "At least one of the parameters is required." }, status: :bad_request if search_params.compact.blank?

    purchase = AdminSearchService.new.search_purchases(**search_params, limit: 1).first
    return render json: { success: false, message: "Purchase not found" }, status: :not_found if purchase.nil?

    purchase_json = purchase.slice(:email, :link_name, :price_cents, :purchase_state, :created_at)
    purchase_json[:id] = purchase.external_id_numeric
    purchase_json[:seller_email] = purchase.seller_email
    purchase_json[:receipt_url] = receipt_purchase_url(purchase.external_id, host: UrlService.domain_with_protocol, email: purchase.email)

    if purchase.refunded?
      purchase_json[:refund_status] = "refunded"
    elsif purchase.stripe_partially_refunded
      purchase_json[:refund_status] = "partially_refunded"
    else
      purchase_json[:refund_status] = nil
    end

    if purchase.amount_refunded_cents > 0
      purchase_json[:refund_amount] = purchase.amount_refunded_cents
    end

    if purchase_json[:refund_status]
      purchase_json[:refund_date] = purchase.refunds.order(:created_at).last&.created_at
    end

    render json: { success: true, message: "Purchase found", purchase: purchase_json }
  rescue AdminSearchService::InvalidDateError
    render json: { success: false, message: "purchase_date must use YYYY-MM-DD format." }, status: :bad_request
  end

  RESEND_RECEIPT_BY_NUMBER_OPENAPI = {
    summary: "Resend receipt by purchase number",
    description: "Resend receipt to customer using purchase number",
    requestBody: {
      required: true,
      content: {
        'application/json': {
          schema: {
            type: "object",
            properties: {
              purchase_number: { type: "string", description: "Purchase number/ID" }
            },
            required: ["purchase_number"]
          }
        }
      }
    },
    security: [{ bearer: [] }],
    responses: {
      '200': {
        description: "Successfully resent receipt",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: true },
                message: { type: "string" }
              }
            }
          }
        },
      },
      '404': {
        description: "Purchase not found",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                message: { type: "string" }
              }
            }
          }
        }
      },
    }
  }.freeze

  def resend_receipt_by_number
    purchase = Purchase.find_by_external_id_numeric(params[:purchase_number].to_i)
    return e404_json unless purchase.present?

    purchase.resend_receipt
    render json: { success: true, message: "Successfully resent receipt for purchase number #{purchase.external_id_numeric} to #{purchase.email}" }
  end

  REFRESH_LIBRARY_OPENAPI = {
    summary: "Refresh purchases in user's library",
    description: "Link purchases with missing purchaser_id to the user account for the given email address",
    requestBody: {
      required: true,
      content: {
        'application/json': {
          schema: {
            type: "object",
            properties: {
              email: { type: "string", description: "Email address of the customer" }
            },
            required: ["email"]
          }
        }
      }
    },
    security: [{ bearer: [] }],
    responses: {
      '200': {
        description: "Successfully refreshed library",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: true },
                message: { type: "string" },
                count: { type: "integer" }
              }
            }
          }
        }
      },
      '404': {
        description: "User not found",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                message: { type: "string" }
              }
            }
          }
        }
      }
    }
  }.freeze

  def refresh_library
    email = params[:email]

    return render json: { success: false, message: "Email address is required" }, status: :bad_request unless email.present?

    user = User.find_by(email: email)
    return render json: { success: false, message: "No user found with email: #{email}" }, status: :not_found unless user.present?

    count = Purchase.where(email: user.email, purchaser_id: nil).update_all(purchaser_id: user.id)

    render json: {
      success: true,
      message: "Successfully refreshed library for #{email}. Updated #{count} purchases.",
      count: count
    }
  end

  REASSIGN_PURCHASES_OPENAPI = {
    summary: "Reassign purchases",
    description: "Update the email on all purchases belonging to the 'from' email address to the 'to' email address",
    requestBody: {
      required: true,
      content: {
        'application/json': {
          schema: {
            type: "object",
            properties: {
              from: { type: "string", description: "Source email address" },
              to: { type: "string", description: "Target email address" }
            },
            required: ["from", "to"]
          }
        }
      }
    },
    security: [{ bearer: [] }],
    responses: {
      '200': {
        description: "Successfully reassigned purchases",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: true },
                message: { type: "string" },
                count: { type: "integer" }
              }
            }
          }
        }
      },
      '400': {
        description: "Missing required parameters",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                message: { type: "string" }
              }
            }
          }
        }
      },
      '404': {
        description: "No purchases found for the given email",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                message: { type: "string" }
              }
            }
          }
        }
      }
    }
  }.freeze

  def reassign_purchases
    from_email = params[:from]
    to_email = params[:to]

    return render json: { success: false, message: "Both 'from' and 'to' email addresses are required" }, status: :bad_request unless from_email.present? && to_email.present?

    purchases = Purchase.where(email: from_email)
    return render json: { success: false, message: "No purchases found for email: #{from_email}" }, status: :not_found if purchases.empty?

    target_user = User.find_by(email: to_email)

    count = 0
    purchases.each do |purchase|
      purchase.email = to_email
      if target_user && purchase.purchaser_id.present?
        purchase.purchaser_id = target_user.id
      else
        purchase.purchaser_id = nil
      end

      if purchase.is_original_subscription_purchase? && purchase.subscription.present?
        if target_user
          purchase.subscription.user = target_user
          purchase.subscription.save
        else
          purchase.subscription.user = nil
          purchase.subscription.save
        end
      end

      count += 1 if purchase.save
    end

    render json: {
      success: true,
      message: "Successfully reassigned #{count} purchases from #{from_email} to #{to_email}",
      count:
    }
  end

  AUTO_REFUND_PURCHASE_OPENAPI = {
    summary: "Auto-refund purchase",
    description: "Allow customers to automatically refund their own purchase. The tool will determine refund eligibility based on refund policy timeframe and absence of fine-print conditions",
    requestBody: {
      required: true,
      content: {
        'application/json': {
          schema: {
            type: "object",
            properties: {
              purchase_id: { type: "string", description: "Purchase ID/number to refund (also referred to as order ID). Can be retrieved using search_purchase endpoint and is not placeholder information" },
              email: { type: "string", description: "Email address of the customer, must match purchase" }
            },
            required: ["purchase_id", "email"]
          }
        }
      }
    },
    security: [{ bearer: [] }],
    responses: {
      '200': {
        description: "Successfully refunded purchase",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: true },
                message: { type: "string" }
              }
            }
          }
        }
      },
      '422': {
        description: "Purchase not refundable",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                message: { type: "string" }
              }
            }
          }
        }
      },
      '404': {
        description: "Purchase not found or email mismatch",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                message: { type: "string" }
              }
            }
          }
        }
      }
    }
  }.freeze

  def auto_refund_purchase
    purchase_id = params[:purchase_id].to_i
    email = params[:email]

    purchase = Purchase.find_by_external_id_numeric(purchase_id)

    unless purchase && purchase.email.downcase == email.downcase
      return render json: { success: false, message: "Purchase not found or email doesn't match" }, status: :not_found
    end

    unless purchase.within_refund_policy_timeframe?
      return render json: { success: false, message: "Purchase is outside of the refund policy timeframe" }, status: :unprocessable_entity
    end

    if purchase.purchase_refund_policy&.fine_print.present?
      return render json: { success: false, message: "This product has specific refund conditions that require seller review" }, status: :unprocessable_entity
    end

    if purchase.refund_and_save!(GUMROAD_ADMIN_ID)
      render json: { success: true, message: "Successfully refunded purchase number #{purchase.external_id_numeric}" }
    else
      render json: { success: false, message: "Refund failed for purchase number #{purchase.external_id_numeric}" }, status: :unprocessable_entity
    end
  end

  REFUND_TAXES_ONLY_OPENAPI = {
    summary: "Refund taxes only",
    description: "Refund only the tax portion of a purchase for tax-exempt customers. Does not refund the product price.",
    requestBody: {
      required: true,
      content: {
        'application/json': {
          schema: {
            type: "object",
            properties: {
              purchase_id: { type: "string", description: "Purchase ID/number to refund taxes for" },
              email: { type: "string", description: "Email address of the customer, must match purchase" },
              note: { type: "string", description: "Optional note for the refund" },
              business_vat_id: { type: "string", description: "Optional business VAT ID for invoice generation" }
            },
            required: ["purchase_id", "email"]
          }
        }
      }
    },
    security: [{ bearer: [] }],
    responses: {
      '200': {
        description: "Successfully refunded taxes",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: true },
                message: { type: "string" }
              }
            }
          }
        }
      },
      '422': {
        description: "No refundable taxes or refund failed",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                message: { type: "string" }
              }
            }
          }
        }
      },
      '404': {
        description: "Purchase not found or email mismatch",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                message: { type: "string" }
              }
            }
          }
        }
      }
    }
  }.freeze

  def refund_taxes_only
    purchase_id = params[:purchase_id]&.to_i
    email = params[:email]

    return render json: { success: false, message: "Both 'purchase_id' and 'email' parameters are required" }, status: :bad_request unless purchase_id.present? && email.present?

    purchase = Purchase.find_by_external_id_numeric(purchase_id)

    unless purchase && purchase.email.downcase == email.downcase
      return render json: { success: false, message: "Purchase not found or email doesn't match" }, status: :not_found
    end

    if purchase.refund_gumroad_taxes!(refunding_user_id: GUMROAD_ADMIN_ID, note: params[:note], business_vat_id: params[:business_vat_id])
      render json: { success: true, message: "Successfully refunded taxes for purchase number #{purchase.external_id_numeric}" }
    else
      error_message = purchase.errors.full_messages.presence&.to_sentence || "No refundable taxes available"
      render json: { success: false, message: error_message }, status: :unprocessable_entity
    end
  end

  private
    def fetch_last_purchase
      @purchase = Purchase.where(email: params[:email]).order(created_at: :desc).first
      e404_json unless @purchase
    end
end
