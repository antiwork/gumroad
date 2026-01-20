# frozen_string_literal: true

class Api::Internal::Helper::UsersController < Api::Internal::Helper::BaseController
  skip_before_action :authorize_helper_token!, only: [:user_info]
  before_action :authorize_hmac_signature!, only: [:user_info]

  def user_info
    render json: { success: false, error: "Tham số 'email' là bắt buộc" }, status: :bad_request if params[:email].blank?

    render json: {
      success: true,
      customer: HelperUserInfoService.new(email: params[:email]).customer_info,
    }
  end

  USER_SUSPENSION_INFO_OPENAPI = {
    summary: "Lấy thông tin đình chỉ tài khoản",
    description: "Lấy trạng thái đình chỉ và chi tiết cho một tài khoản",
    requestBody: {
      required: true,
      content: {
        'application/json': {
          schema: {
            type: "object",
            properties: {
              email: { type: "string", description: "Địa chỉ email của người dùng" }
            },
            required: ["email"]
          }
        }
      }
    },
    security: [{ bearer: [] }],
    responses: {
      '200': {
        description: "Lấy thông tin đình chỉ tài khoản thành công",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { type: "boolean" },
                status: { type: "string", description: "Trạng thái tài khoản" },
                updated_at: { type: "string", format: "date-time", nullable: true, description: "Thời gian cập nhật trạng thái đình chỉ tài khoản" },
                appeal_url: { type: "string", nullable: true, description: "URL để kháng nghị đình chỉ tài khoản" }
              }
            }
          }
        }
      },
      '400': {
        description: "Thiếu tham số bắt buộc",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                error: { type: "string" }
              }
            }
          }
        }
      },
      '422': {
        description: "Không tìm thấy tài khoản",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                error_message: { type: "string" }
              }
            }
          }
        }
      }
    }
  }.freeze
  def user_suspension_info
    if params[:email].blank?
      render json: { success: false, error: "Tham số 'email' là bắt buộc" }, status: :bad_request
      return
    end

    user = User.alive.by_email(params[:email]).first
    if user.blank?
      return render json: { success: false, error_message: "Không có tài khoản nào tồn tại với email đó." }, status: :unprocessable_entity
    end

    iffy_url = Rails.env.production? ? "https://api.iffy.com/api/v1/users" : "http://localhost:3000/api/v1/users"

    begin
      if user.suspended?
        render json: {
          success: true,
          status: "Suspended",
          updated_at: user.comments.where(comment_type: [Comment::COMMENT_TYPE_SUSPENSION_NOTE, Comment::COMMENT_TYPE_SUSPENDED]).order(created_at: :desc).first&.created_at,
          appeal_url: nil
        }
        return
      end

      response = HTTParty.get(
        "#{iffy_url}?email=#{CGI.escape(params[:email])}",
        headers: {
          "Authorization" => "Bearer #{GlobalConfig.get("IFFY_API_KEY")}"
        }
      )

      if response.success? && response.parsed_response["data"].present? && !response.parsed_response["data"].empty?
        user_data = response.parsed_response["data"].first
        render json: {
          success: true,
          status: user_data["actionStatus"],
          updated_at: user_data["actionStatusCreatedAt"],
          appeal_url: user_data["appealUrl"]
        }
      else
        render json: {
          success: true,
          status: "Compliant",
          updated_at: nil,
          appeal_url: nil
        }
      end
    rescue HTTParty::Error, Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, Errno::ECONNREFUSED, SocketError => e
      Bugsnag.notify(e)

      render json: {
        success: false,
        error_message: "Không thể lấy thông tin đình chỉ"
      }, status: :service_unavailable
    end
  end

  SEND_RESET_PASSWORD_INSTRUCTIONS_OPENAPI = {
    summary: "Gửi yêu cầu đặt lại mật khẩu",
    description: "Gửi email chứa hướng dẫn đặt lại mật khẩu",
    requestBody: {
      required: true,
      content: {
        'application/json': {
          schema: {
            type: "object",
            properties: {
              email: { type: "string", description: "Địa chỉ email của khách hàng" }
            },
            required: ["email"]
          }
        }
      }
    },
    security: [{ bearer: [] }],
    responses: {
      '200': {
        description: "Gửi yêu cầu đặt lại mật khẩu thành công",
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
        description: "Email không hợp lệ hoặc không tìm thấy tài khoản",
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
  def send_reset_password_instructions
    if EmailFormatValidator.valid?(params[:email])
      user = User.alive.by_email(params[:email]).first
      if user
        user.send_reset_password_instructions
        render json: { success: true, message: "Gửi yêu cầu đặt lại mật khẩu thành công" }
      else
        render json: { error_message: "Không có tài khoản nào tồn tại với email đó." },
               status: :unprocessable_entity
      end
    else
      render json: { error_message: "Email không hợp lệ" }, status: :unprocessable_entity
    end
  end

  UPDATE_EMAIL_OPENAPI = {
    summary: "Cập nhật email người dùng",
    description: "Cập nhật địa chỉ email của người dùng",
    requestBody: {
      required: true,
      content: {
        'application/json': {
          schema: {
            type: "object",
            properties: {
              current_email: { type: "string", description: "Địa chỉ email hiện tại của người dùng" },
              new_email: { type: "string", description: "Địa chỉ email mới của người dùng" }
            },
            required: ["current_email", "new_email"]
          }
        }
      }
    },
    security: [{ bearer: [] }],
    responses: {
      '200': {
        description: "Cập nhật email thành công",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                message: { type: "string" }
              }
            }
          }
        }
      },
      '422': {
        description: "Email không hợp lệ hoặc không tìm thấy người dùng",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                error_message: { type: "string" }
              }
            }
          }
        }
      }
    }
  }.freeze
  def update_email
    if params[:current_email].blank? || params[:new_email].blank?
      render json: { error_message: "Cả email hiện tại và email mới đều bắt buộc." }, status: :unprocessable_entity
      return
    end

    if !EmailFormatValidator.valid?(params[:new_email])
      render json: { error_message: "Định dạng email mới không hợp lệ." }, status: :unprocessable_entity
      return
    end

    user = User.alive.by_email(params[:current_email]).first
    if user
      user.email = params[:new_email]
      if user.save
        render json: { message: "Đã cập nhật email." }
      else
        render json: { error_message: user.errors.full_messages.join(", ") }, status: :unprocessable_entity
      end
    else
      render json: { error_message: "Không có tài khoản nào tồn tại với email đó." }, status: :unprocessable_entity
    end
  end

  UPDATE_TWO_FACTOR_AUTHENTICATION_ENABLED_OPENAPI = {
    summary: "Cập nhật trạng thái xác thực hai yếu tố",
    description: "Cập nhật trạng thái xác thực hai yếu tố của người dùng",
    requestBody: {
      required: true,
      content: {
        'application/json': {
          schema: {
            type: "object",
            properties: {
              email: { type: "string", description: "Địa chỉ email của người dùng" },
              enabled: { type: "boolean", description: "Bật hoặc tắt xác thực hai yếu tố" }
            },
            required: ["email", "enabled"]
          }
        }
      }
    },
    security: [{ bearer: [] }],
    responses: {
      '200': {
        description: "Cập nhật trạng thái xác thực hai yếu tố thành công",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { type: "boolean" },
                message: { type: "string" }
              }
            }
          }
        }
      },
      '422': {
        description: "Email không hợp lệ hoặc không tìm thấy người dùng",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { type: "boolean" },
                error_message: { type: "string" }
              }
            }
          }
        }
      }
    }
  }.freeze

  def update_two_factor_authentication_enabled
    if params[:email].blank?
      return render json: { success: false, error_message: "Email là bắt buộc." }, status: :unprocessable_entity
    end

    if params[:enabled].nil?
      return render json: { success: false, error_message: "Trạng thái bật/tắt là bắt buộc." }, status: :unprocessable_entity
    end

    user = User.alive.by_email(params[:email]).first
    if user.present?
      user.two_factor_authentication_enabled = params[:enabled]
      if user.save
        render json: { success: true, message: "Xác thực hai yếu tố đã được #{user.two_factor_authentication_enabled? ? "bật" : "tắt"}." }
      else
        render json: { success: false, error_message: user.errors.full_messages.join(", ") }, status: :unprocessable_entity
      end
    else
      render json: { success: false, error_message: "Không có tài khoản nào tồn tại với email đó." }, status: :unprocessable_entity
    end
  end

  CREATE_USER_APPEAL_OPENAPI = {
    summary: "Tạo kháng nghị người dùng",
    description: "Tạo kháng nghị cho người dùng bị đình chỉ khi họ tin rằng họ bị đình chỉ nhầm",
    requestBody: {
      required: true,
      content: {
        'application/json': {
          schema: {
            type: "object",
            properties: {
              email: { type: "string", description: "Địa chỉ email của người dùng" },
              reason: { type: "string", description: "Lý do kháng nghị" }
            },
            required: ["email", "reason"]
          }
        }
      }
    },
    security: [{ bearer: [] }],
    responses: {
      '200': {
        description: "Tạo kháng nghị thành công",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: true },
                id: { type: "string", description: "ID của kháng nghị" },
                appeal_url: { type: "string", description: "URL để người dùng xem kháng nghị của họ"  }
              }
            }
          }
        }
      },
      '400': {
        description: "Tham số không hợp lệ",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                error_message: { type: "string" }
              }
            }
          }
        }
      },
      '422': {
        description: "Không tìm thấy người dùng hoặc tạo kháng nghị thất bại",
        content: {
          'application/json': {
            schema: {
              type: "object",
              properties: {
                success: { const: false },
                error_message: { type: "string" }
              }
            }
          }
        }
      }
    }
  }.freeze

  def create_appeal
    if params[:email].blank?
      return render json: { success: false, error_message: "Tham số 'email' là bắt buộc" }, status: :bad_request
    end

    if params[:reason].blank?
      return render json: { success: false, error_message: "Tham số 'reason' là bắt buộc" }, status: :bad_request
    end

    user = User.alive.by_email(params[:email]).first
    if user.blank?
      return render json: { success: false, error_message: "Không có tài khoản nào tồn tại với email đó." }, status: :unprocessable_entity
    end

    iffy_url = Rails.env.production? ? "https://api.iffy.com/api/v1" : "http://localhost:3000/api/v1"

    begin
      response = HTTParty.get(
        "#{iffy_url}/users?email=#{CGI.escape(params[:email])}",
        headers: {
          "Authorization" => "Bearer #{GlobalConfig.get("IFFY_API_KEY")}"
        }
      )

      if !(response.success? && response.parsed_response["data"].present? && !response.parsed_response["data"].empty?)
        error_message = response.parsed_response.is_a?(Hash) ? response.parsed_response["error"]&.[]("message") || "Không tìm thấy người dùng" : "Không tìm thấy người dùng"
        return render json: { success: false, error_message: error_message }, status: :unprocessable_entity
      end

      user_data = response.parsed_response["data"].first
      user_id = user_data["id"]

      response = HTTParty.post(
        "#{iffy_url}/users/#{user_id}/create_appeal",
        headers: {
          "Authorization" => "Bearer #{GlobalConfig.get("IFFY_API_KEY")}",
          "Content-Type" => "application/json"
        },
        body: {
          text: params[:reason]
        }.to_json
      )

      if !(response.success? && response.parsed_response["data"].present? && !response.parsed_response["data"].empty?)
        error_message = response.parsed_response.dig("error", "message") || "Tạo kháng nghị thất bại"
        return render json: { success: false, error_message: }, status: :unprocessable_entity
      end

      appeal_data = response.parsed_response["data"]
      appeal_id = appeal_data["id"]
      appeal_url = appeal_data["appealUrl"]

      render json: {
        success: true,
        id: appeal_id,
        appeal_url: appeal_url
      }
    rescue HTTParty::Error, Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, Errno::ECONNREFUSED, SocketError => e
      Bugsnag.notify(e)

      render json: {
        success: false,
        error_message: "Tạo kháng nghị thất bại"
      }, status: :service_unavailable
    end
  end
end
