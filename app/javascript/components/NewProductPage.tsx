import { Link } from "@inertiajs/react";
import cx from "classnames";
import hands from "images/illustrations/hands.png";
import * as React from "react";
import { useState } from "react";
import { cast, is } from "ts-safe-cast";

import { CreateProductData, RecurringProductType, createProduct } from "$app/data/products";
import { ProductNativeType, ProductServiceType } from "$app/parsers/product";
import { CurrencyCode, currencyCodeList, findCurrencyByCode } from "$app/utils/currency";
import {
  RecurrenceId,
  durationInMonthsToRecurrenceId,
  recurrenceLabels,
  recurrenceIds,
} from "$app/utils/recurringPricing";
import { assertResponseError, request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { Alert } from "$app/components/ui/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Pill } from "$app/components/ui/Pill";
import { WithTooltip } from "$app/components/WithTooltip";

const nativeTypeIcons = require.context("$assets/images/native_types/");

const defaultRecurrence: RecurrenceId = "monthly";

const MIN_AI_PROMPT_LENGTH = 10;

export type NewProductPageProps = {
  current_seller_currency_code: CurrencyCode;
  native_product_types: ProductNativeType[];
  service_product_types: ProductServiceType[];
  release_at_date: string;
  show_orientation_text: boolean;
  eligible_for_service_products: boolean;
  ai_generation_enabled: boolean;
  ai_promo_dismissed: boolean;
};

const NewProductPage = ({
  current_seller_currency_code,
  native_product_types,
  service_product_types,
  release_at_date,
  show_orientation_text,
  eligible_for_service_products,
  ai_generation_enabled,
  ai_promo_dismissed,
}: NewProductPageProps) => {
  const formUID = React.useId();
  const nameInputRef = React.useRef<HTMLInputElement>(null);
  const priceInputRef = React.useRef<HTMLInputElement>(null);

  const [errors, setErrors] = useState<Set<string>>(new Set());
  const [name, setName] = useState("");
  const [price, setPrice] = useState("");
  const [isSubmitting, setIsSubmitting] = React.useState(false);
  const [currencyCode, setCurrencyCode] = useState<CurrencyCode>(current_seller_currency_code);
  const [productType, setProductType] = useState<ProductNativeType>("digital");
  const [subscriptionDuration, setSubscriptionDuration] = useState<RecurrenceId | null>(null);

  const [aiPromoVisible, setAiPromoVisible] = useState(ai_generation_enabled && !ai_promo_dismissed);
  const [aiPopoverOpen, setAiPopoverOpen] = useState(false);
  const [aiPrompt, setAiPrompt] = useState("");
  const [isGeneratingUsingAi, setIsGeneratingUsingAi] = useState(false);
  const [description, setDescription] = useState<string | null>(null);
  const [summary, setSummary] = useState<string | null>(null);
  const [numberOfContentPages, setNumberOfContentPages] = useState<number | null>(null);

  const isRecurringBilling = is<RecurringProductType>(productType);

  const selectedCurrency = findCurrencyByCode(currencyCode);

  const dismissAiPromo = async () => {
    try {
      await request({
        method: "POST",
        url: Routes.settings_dismiss_ai_product_generation_promo_path(),
        accept: "json",
      });
      setAiPromoVisible(false);
    } catch (e) {
      assertResponseError(e);
      showAlert("Không thể bỏ qua quảng cáo", "error");
    }
  };

  const generateWithAi = async () => {
    if (aiPrompt.trim().length < MIN_AI_PROMPT_LENGTH) {
      showAlert(
        `Vui lòng nhập lời nhắc chi tiết cho ý tưởng sản phẩm của bạn với mức giá dự kiến (tối thiểu ${MIN_AI_PROMPT_LENGTH} ký tự)`,
        "error",
      );
      return;
    }

    setIsGeneratingUsingAi(true);
    try {
      const response = await request({
        method: "POST",
        url: Routes.internal_ai_product_details_generations_path(),
        accept: "json",
        data: { prompt: aiPrompt.trim() },
      });

      const result = cast<
        | {
            success: true;
            data: {
              name: string;
              description: string;
              summary: string;
              price: number;
              currency_code: string;
              price_frequency_in_months: number | null;
              native_type: ProductNativeType;
              number_of_content_pages: number | null;
            };
          }
        | {
            success: false;
            error: string;
          }
      >(await response.json());

      if (result.success) {
        const data = result.data;

        setName(data.name);
        setDescription(data.description);
        setSummary(data.summary);
        setProductType(data.native_type);
        setNumberOfContentPages(data.number_of_content_pages);
        setPrice(data.price.toString());
        if (is<CurrencyCode>(data.currency_code)) {
          setCurrencyCode(data.currency_code);
        }
        if (data.native_type === "membership" && data.price_frequency_in_months) {
          const recurrenceId = durationInMonthsToRecurrenceId[data.price_frequency_in_months];
          setSubscriptionDuration(recurrenceId || defaultRecurrence);
        }

        setAiPopoverOpen(false);
        setAiPromoVisible(false);

        showAlert("Đã xong! Xem lại biểu mẫu bên dưới và nhấn 'Tiếp theo: Tùy chỉnh' để tiếp tục.", "success");
      } else {
        showAlert(result.error, "error");
      }
    } catch (e) {
      assertResponseError(e);
      showAlert("Không thể tạo chi tiết sản phẩm", "error");
    } finally {
      setIsGeneratingUsingAi(false);
    }
  };

  const submit = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const errors = new Set<string>();

    if (name.trim() === "") {
      errors.add("name");
      nameInputRef.current?.focus();
    } else if (price.trim() === "") {
      errors.add("price");
      priceInputRef.current?.focus();
    }

    setErrors(errors);
    if (errors.size > 0) return false;

    setIsSubmitting(true);

    try {
      const requestData = {
        link: cast<CreateProductData>({
          is_physical: productType === "physical",
          is_recurring_billing: isRecurringBilling,
          name,
          description,
          summary,
          native_type: productType,
          price_currency_type: currencyCode,
          price_range: price,
          release_at_date,
          release_at_time: "12PM",
          subscription_duration: isRecurringBilling ? subscriptionDuration || defaultRecurrence : null,
          number_of_content_pages: numberOfContentPages,
          ai_prompt: aiPrompt.trim(),
        }),
      };

      const responseData = await createProduct(requestData);

      if (responseData.success) {
        let redirectTo = responseData.redirect_to;
        if (aiPrompt.trim().length > 0) {
          redirectTo = `${redirectTo}#ai-generated`;
        }

        window.location.href = redirectTo;
      } else {
        showAlert(responseData.error_message, "error");
      }
    } catch (e) {
      assertResponseError(e);
      showAlert("Đã xảy ra lỗi.", "error");
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <>
      <PageHeader
        className="sticky-top"
        title={show_orientation_text ? "Xuất bản sản phẩm đầu tiên của bạn" : "Bạn đang tạo gì?"}
        actions={
          <>
            <Button asChild>
              <Link href={Routes.products_path()}>
                <Icon name="x-square" />
                <span>Hủy</span>
              </Link>
            </Button>
            {ai_generation_enabled ? (
              <Popover
                open={aiPopoverOpen}
                onToggle={setAiPopoverOpen}
                trigger={
                  <Button color="primary" outline aria-label="Tạo sản phẩm bằng AI">
                    <Icon name="sparkle" />
                  </Button>
                }
              >
                <div className="w-96 max-w-full">
                  <fieldset>
                    <legend>
                      <label htmlFor={`ai-prompt-${formUID}`}>Tạo sản phẩm bằng AI</label>
                    </legend>
                    <p>
                      Có ý tưởng? Hãy đưa ra hướng dẫn rõ ràng và để AI tạo sản phẩm cho bạn—nhanh chóng và dễ dàng! Tùy chỉnh để biến nó thành của bạn.
                    </p>
                    <textarea
                      id={`ai-prompt-${formUID}`}
                      placeholder="ví dụ: ebook 'Lập trình với AI bằng Cursor cho Nhà thiết kế' gồm 5 chương với giá $35'."
                      value={aiPrompt}
                      onChange={(e) => setAiPrompt(e.target.value)}
                      rows={4}
                      maxLength={500}
                      className="w-full resize-y"
                      autoFocus
                    />
                  </fieldset>
                  <div className="mt-3 flex justify-end gap-2">
                    <Button onClick={() => setAiPopoverOpen(false)} disabled={isGeneratingUsingAi}>
                      Hủy
                    </Button>
                    <Button
                      color="primary"
                      onClick={() => void generateWithAi()}
                      disabled={isGeneratingUsingAi || !aiPrompt.trim()}
                    >
                      {isGeneratingUsingAi ? "Đang tạo..." : "Tạo"}
                    </Button>
                  </div>
                </div>
              </Popover>
            ) : null}
            <Button color="accent" type="submit" form={`new-product-form-${formUID}`} disabled={isSubmitting}>
              {isSubmitting ? "Đang thêm..." : "Tiếp theo: Tùy chỉnh"}
            </Button>
          </>
        }
      />
      <div>
        <div>
          <form id={`new-product-form-${formUID}`} className="row" onSubmit={(e) => void submit(e)}>
            <section className="p-4! md:p-8!">
              <header>
                <p>
                  Biến ý tưởng của bạn thành sản phẩm thực tế trong vài phút. Không rắc rối, chỉ cần vài lựa chọn nhanh là bạn đã sẵn sàng bán hàng.
                  Cho dù là tải xuống kỹ thuật số, khóa học trực tuyến hay gói thành viên — hãy xem điều gì phù hợp.
                  <br />
                  <br />
                  <a href="/help/article/64-is-gumroad-for-me" target="_blank" rel="noreferrer">
                    Cần trợ giúp thêm sản phẩm?
                  </a>
                </p>
              </header>

              {ai_generation_enabled && aiPromoVisible ? (
                <Alert className="gap-4 p-6" role="status" variant="accent">
                  <div className="flex items-center gap-4">
                    <img src={hands} alt="Hands" className="size-12" />
                    <div className="flex-1">
                      <strong>Mới.</strong> Bây giờ bạn có thể tạo sản phẩm bằng AI. Nhấp vào nút tia lửa ở tiêu đề để bắt đầu.
                      <br />
                      <a href="/help/article/149-adding-a-product" target="_blank" rel="noreferrer">
                        Tìm hiểu thêm
                      </a>
                    </div>
                    <button className="cursor-pointer underline all-unset" onClick={() => void dismissAiPromo()}>
                      đóng
                    </button>
                  </div>
                </Alert>
              ) : null}

              <fieldset className={cx({ danger: errors.has("name") })}>
                <legend>
                  <label htmlFor={`name-${formUID}`}>Tên</label>
                </legend>

                <input
                  ref={nameInputRef}
                  id={`name-${formUID}`}
                  type="text"
                  placeholder="Tên sản phẩm"
                  value={name}
                  onChange={(e) => {
                    setName(e.target.value);
                    errors.delete("name");
                  }}
                  aria-invalid={errors.has("name")}
                />
              </fieldset>

              <fieldset>
                <legend>Sản phẩm</legend>
                <ProductTypeSelector
                  selectedType={productType}
                  types={native_product_types}
                  onChange={setProductType}
                />
              </fieldset>
              {service_product_types.length > 0 ? (
                <fieldset>
                  <legend>Dịch vụ</legend>
                  <ProductTypeSelector
                    selectedType={productType}
                    types={service_product_types}
                    onChange={setProductType}
                    disabled={!eligible_for_service_products}
                  />
                </fieldset>
              ) : null}

              <fieldset className={cx({ danger: errors.has("price") })}>
                <legend>
                  <label htmlFor={`price-${formUID}`}>{productType === "coffee" ? "Số tiền đề xuất" : "Giá"}</label>
                </legend>

                <div className="input">
                  <Pill asChild className="relative -ml-2 shrink-0 cursor-pointer">
                    <label>
                      <span>{selectedCurrency.longSymbol}</span>
                      <TypeSafeOptionSelect
                        onChange={(newCurrencyCode) => {
                          setCurrencyCode(newCurrencyCode);
                        }}
                        value={currencyCode}
                        aria-label="Tiền tệ"
                        options={currencyCodeList.map((code) => {
                          const { displayFormat } = findCurrencyByCode(code);
                          return {
                            id: code,
                            label: displayFormat,
                          };
                        })}
                        className="absolute inset-0 z-1 m-0! cursor-pointer opacity-0"
                      />
                      <Icon name="outline-cheveron-down" className="ml-auto" />
                    </label>
                  </Pill>

                  <input
                    ref={priceInputRef}
                    id={`price-${formUID}`}
                    type="text"
                    inputMode="decimal"
                    maxLength={10}
                    placeholder="Định giá sản phẩm của bạn"
                    value={price}
                    onChange={(e) => {
                      let newValue = e.target.value;
                      newValue = newValue.replace(/[.,]+/gu, ".");
                      newValue = newValue.replace(/[^0-9.]/gu, "");
                      setPrice(newValue);
                      errors.delete("price");
                    }}
                    autoComplete="off"
                    aria-invalid={errors.has("price")}
                  />

                  {isRecurringBilling ? (
                    <Pill asChild className="relative -mr-2 shrink-0 cursor-pointer">
                      <label>
                        <span>{recurrenceLabels[subscriptionDuration || defaultRecurrence]}</span>
                        <TypeSafeOptionSelect
                          onChange={(newSubscriptionDuration) => {
                            setSubscriptionDuration(newSubscriptionDuration);
                          }}
                          value={subscriptionDuration || defaultRecurrence}
                          aria-label="Thời hạn đăng ký mặc định"
                          options={recurrenceIds.map((recurrence) => ({
                            id: recurrence,
                            label: recurrenceLabels[recurrence],
                          }))}
                          className="absolute inset-0 z-1 m-0! cursor-pointer opacity-0"
                        />
                        <Icon name="outline-cheveron-down" className="ml-auto" />
                      </label>
                    </Pill>
                  ) : null}
                </div>
              </fieldset>
            </section>
          </form>
        </div>
      </div>
    </>
  );
};

export default NewProductPage;

const PRODUCT_TYPES = {
  audiobook: {
    description: "Cho phép khách hàng nghe nội dung âm thanh của bạn.",
    title: "Sách nói",
  },
  bundle: {
    description: "Bán hai hoặc nhiều sản phẩm hiện có với giá mới",
    title: "Gói combo",
  },
  call: {
    description: "Cung cấp các cuộc gọi theo lịch trình với khách hàng của bạn.",
    title: "Cuộc gọi",
  },
  coffee: {
    description: "Tăng cường sự ủng hộ và chấp nhận tiền boa từ khách hàng.",
    title: "Cà phê (Ủng hộ)",
  },
  commission: {
    description: "Bán dịch vụ tùy chỉnh với khoản đặt cọc trước 50%, 50% khi hoàn thành.",
    title: "Hoa hồng",
  },
  course: {
    description: "Bán một bài học hoặc dạy cả một nhóm học viên.",
    title: "Khóa học hoặc hướng dẫn",
  },
  digital: {
    description: "Bất kỳ tập tin nào để tải xuống hoặc phát trực tuyến.",
    title: "Sản phẩm số",
  },
  ebook: {
    description: "Cung cấp sách hoặc truyện tranh ở định dạng PDF, ePub và Mobi.",
    title: "Sách điện tử",
  },
  membership: {
    description: "Bắt đầu kinh doanh gói thành viên dành cho người hâm mộ.",
    title: "Gói thành viên",
  },
  newsletter: {
    description: "Gửi nội dung định kỳ qua email.",
    title: "Bản tin",
  },
  physical: {
    description: "Bán bất cứ thứ gì cần vận chuyển.",
    title: "Hàng vật lý",
  },
  podcast: {
    description: "Cung cấp các tập để phát trực tuyến và tải xuống trực tiếp.",
    title: "Podcast",
  },
};

const ProductTypeSelector = ({
  selectedType,
  types,
  onChange,
  disabled,
}: {
  selectedType: ProductNativeType;
  types: ProductNativeType[];
  onChange: (type: ProductNativeType) => void;
  disabled?: boolean;
}) => (
  <div className="radio-buttons grid-cols-1! sm:grid-cols-2! md:grid-cols-3! 2xl:grid-cols-5!" role="radiogroup">
    {types.map((type) => {
      const typeButton = (
        <Button
          key={type}
          className="vertical"
          role="radio"
          aria-checked={type === selectedType}
          data-type={type}
          onClick={() => onChange(type)}
          disabled={disabled}
        >
          <img
            src={cast<string>(nativeTypeIcons(`./${type}.png`))}
            alt={PRODUCT_TYPES[type].title}
            width="40"
            height="40"
          />
          <div>
            <h4>{PRODUCT_TYPES[type].title}</h4>
            {PRODUCT_TYPES[type].description}
          </div>
        </Button>
      );
      return disabled ? (
        <WithTooltip tip="Sản phẩm dịch vụ bị vô hiệu hóa cho đến khi tài khoản của bạn đủ 30 ngày tuổi." key={type}>
          {typeButton}
        </WithTooltip>
      ) : (
        typeButton
      );
    })}
    {types.length < 2 ? <div /> : null}
    {types.length < 3 ? <div /> : null}
  </div>
);
