import { Editor } from "@tiptap/core";
import cx from "classnames";
import { format } from "date-fns";
import * as React from "react";

import { sendSamplePriceChangeEmail } from "$app/data/membership_tiers";
import { getIsSingleUnitCurrency } from "$app/utils/currency";
import { priceCentsToUnit } from "$app/utils/price";
import {
  numberOfMonthsInRecurrence,
  RecurrenceId,
  perRecurrenceLabels,
  recurrenceNames,
} from "$app/utils/recurringPricing";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { DateInput } from "$app/components/DateInput";
import { Details } from "$app/components/Details";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { NumberInput } from "$app/components/NumberInput";
import { PriceInput } from "$app/components/PriceInput";
import { useProductUrl } from "$app/components/ProductEdit/Layout";
import { RecurrencePriceValue, Tier, useProductEditContext } from "$app/components/ProductEdit/state";
import { RichTextEditor } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import { Drawer, ReorderingHandle, SortableList } from "$app/components/SortableList";
import { Toggle } from "$app/components/Toggle";
import { Alert } from "$app/components/ui/Alert";
import { Placeholder } from "$app/components/ui/Placeholder";
import { Row, RowActions, RowContent, RowDetails, Rows } from "$app/components/ui/Rows";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useRunOnce } from "$app/components/useRunOnce";
import { WithTooltip } from "$app/components/WithTooltip";

let newTierId = 0;

const areAllEnabledPricesZero = (recurrencePriceValues: Record<string, RecurrencePriceValue>): boolean => {
  const enabledPrices = Object.values(recurrencePriceValues).filter((value) => value.enabled);
  return enabledPrices.length > 0 && enabledPrices.every((value) => !value.price_cents || value.price_cents === 0);
};

export const TiersEditor = ({ tiers, onChange }: { tiers: Tier[]; onChange: (tiers: Tier[]) => void }) => {
  const updateVersion = (id: string, update: Partial<Tier>) => {
    onChange(tiers.map((version) => (version.id === id ? { ...version, ...update } : version)));
  };

  const [deletionModalVersionId, setDeletionModalVersionId] = React.useState<string | null>(null);
  const deletionModalVersion = tiers.find(({ id }) => id === deletionModalVersionId);

  const addButton = (
    <Button
      color="primary"
      onClick={() => {
        onChange([
          ...tiers,
          {
            id: (newTierId++).toString(),
            name: "Chưa đặt tên",
            description: "",
            max_purchase_count: null,
            customizable_price: false,
            apply_price_changes_to_existing_memberships: false,
            subscription_price_change_effective_date: null,
            subscription_price_change_message: null,
            recurrence_price_values: {
              monthly: { enabled: false },
              quarterly: { enabled: false },
              biannually: { enabled: false },
              yearly: { enabled: false },
              every_two_years: { enabled: false },
            },
            integrations: { discord: false, circle: false, google_calendar: false },
            newlyAdded: true,
            rich_content: [],
          },
        ]);
      }}
    >
      <Icon name="plus" />
      Thêm cấp bậc
    </Button>
  );

  return tiers.length === 0 ? (
    <Placeholder>
      <h2>Cung cấp các cấp bậc khác nhau của tư cách thành viên này</h2>
      Thu hút khách hàng với các cấp độ truy cập khác nhau. Mỗi tư cách thành viên cần ít nhất một cấp bậc.
      {addButton}
    </Placeholder>
  ) : (
    <>
      {deletionModalVersion ? (
        <Modal
          open={!!deletionModalVersion}
          onClose={() => setDeletionModalVersionId(null)}
          title={`Remove ${deletionModalVersion.name}?`}
          footer={
            <>
              <Button onClick={() => setDeletionModalVersionId(null)}>Không, hủy</Button>
              <Button color="accent" onClick={() => onChange(tiers.filter(({ id }) => id !== deletionModalVersion.id))}>
                Có, xóa
              </Button>
            </>
          }
        >
          Nếu bạn xóa cấp bậc này, nội dung liên quan cũng sẽ bị xóa. Khách hàng hiện tại đã mua sẽ thấy nội dung
          từ cấp bậc rẻ nhất hiện tại làm dự phòng. Nếu không có cấp bậc nào, họ sẽ thấy nội dung cấp sản phẩm.
        </Modal>
      ) : null}
      <SortableList
        currentOrder={tiers.map(({ id }) => id)}
        onReorder={(newOrder) => onChange(newOrder.flatMap((id) => tiers.find((version) => version.id === id) ?? []))}
        tag={SortableTierEditors}
      >
        {tiers.map((version) => (
          <TierEditor
            key={version.id}
            tier={version}
            updateTier={(update) => updateVersion(version.id, update)}
            onDelete={() => setDeletionModalVersionId(version.id)}
          />
        ))}
      </SortableList>
      {addButton}
    </>
  );
};

const PLACEHOLDER_VALUES = { monthly: "5", quarterly: "15", biannually: "30", yearly: "60", every_two_years: "120" };

const TierEditor = ({
  tier,
  updateTier,
  onDelete,
}: {
  tier: Tier;
  updateTier: (update: Partial<Tier>) => void;
  onDelete: () => void;
}) => {
  const uid = React.useId();
  const { product, currencyType } = useProductEditContext();

  const [isOpen, setIsOpen] = React.useState(true);

  const url = useProductUrl({ option: tier.id });

  const updateRecurrencePriceValue = (recurrence: RecurrenceId, update: Partial<RecurrencePriceValue>) => {
    const updatedRecurrencePriceValues = {
      ...tier.recurrence_price_values,
      [recurrence]: { ...tier.recurrence_price_values[recurrence], ...update },
    };

    updateTier({
      recurrence_price_values: updatedRecurrencePriceValues,
      ...(areAllEnabledPricesZero(updatedRecurrencePriceValues) && { customizable_price: true }),
    });
  };

  const defaultRecurrencePriceValue = product.subscription_duration
    ? tier.recurrence_price_values[product.subscription_duration]
    : null;
  React.useEffect(() => {
    if (product.subscription_duration) {
      if (defaultRecurrencePriceValue?.price_cents) {
        const defaultPriceProratedPerMonth =
          defaultRecurrencePriceValue.price_cents / numberOfMonthsInRecurrence(product.subscription_duration);
        updateTier({
          recurrence_price_values: Object.fromEntries(
            Object.entries(tier.recurrence_price_values).map(([r, v]) => [
              r,
              {
                ...v,
                price_cents: v.enabled ? v.price_cents : defaultPriceProratedPerMonth * numberOfMonthsInRecurrence(r),
              },
            ]),
          ),
        });
      }
    }
  }, [defaultRecurrencePriceValue?.price_cents]);

  const integrations = Object.entries(product.integrations)
    .filter(([_, enabled]) => enabled)
    .map(([name]) => name);

  const allEnabledPricesAreZero = areAllEnabledPricesZero(tier.recurrence_price_values);

  return (
    <Row role="listitem">
      <RowContent>
        <ReorderingHandle />
        <Icon name="stack-fill" />
        <div>
          <h3>{tier.name || "Untitled"}</h3>
          {tier.active_subscribers_count ? (
            <small>
              {tier.active_subscribers_count} {tier.active_subscribers_count === 1 ? "người hỗ trợ" : "người hỗ trợ"}
            </small>
          ) : null}
        </div>
      </RowContent>
      <RowActions>
        <WithTooltip tip={isOpen ? "Đóng" : "Mở"}>
          <Button onClick={() => setIsOpen((prevIsOpen) => !prevIsOpen)}>
            <Icon name={isOpen ? "outline-cheveron-up" : "outline-cheveron-down"} />
          </Button>
        </WithTooltip>
        <WithTooltip tip="Xóa">
          <Button onClick={onDelete} aria-label="Xóa">
            <Icon name="trash2" />
          </Button>
        </WithTooltip>
      </RowActions>
      {isOpen ? (
        <RowDetails asChild>
          <Drawer className="grid gap-6">
            <fieldset>
              <label htmlFor={`${uid}-name`}>Tên</label>
              <div className="input">
                <input
                  id={`${uid}-name`}
                  type="text"
                  value={tier.name}
                  onChange={(evt) => updateTier({ name: evt.target.value })}
                />
                <a href={url} target="_blank" rel="noreferrer">
                  Chia sẻ
                </a>
              </div>
            </fieldset>
            <fieldset>
              <label htmlFor={`${uid}-description`}>Mô tả</label>
              <textarea
                id={`${uid}-description`}
                value={tier.description}
                onChange={(evt) => updateTier({ description: evt.target.value })}
              />
            </fieldset>
            <fieldset>
              <label htmlFor={`${uid}-max-purchase-count`}>Số lượng người hỗ trợ tối đa</label>
              <NumberInput
                onChange={(value) => updateTier({ max_purchase_count: value })}
                value={tier.max_purchase_count}
              >
                {(inputProps) => (
                  <input id={`${uid}-max-purchase-count`} type="number" placeholder="∞" {...inputProps} />
                )}
              </NumberInput>
            </fieldset>
            <fieldset
              style={{
                display: "grid",
                gap: "var(--spacer-3)",
                gridTemplateColumns: "repeat(auto-fit, max(var(--dynamic-grid), 50% - var(--spacer-3) / 2))",
              }}
            >
              <legend>Giá</legend>
              {Object.entries(tier.recurrence_price_values).map(([recurrence, value]) => (
                <div
                  style={{
                    display: "grid",
                    gridTemplateColumns: "max-content 1fr",
                    alignItems: "center",
                    gap: "var(--spacer-2)",
                  }}
                  key={recurrence}
                >
                  <input
                    type="checkbox"
                    role="switch"
                    checked={value.enabled}
                    aria-label={`Chuyển đổi tùy chọn lặp lại: ${recurrenceNames[recurrence]}`}
                    onChange={() => updateRecurrencePriceValue(recurrence, { enabled: !value.enabled })}
                  />
                  <PriceInput
                    id={`${uid}-price`}
                    currencyCode={currencyType}
                    cents={value.price_cents ?? null}
                    onChange={(price_cents) => updateRecurrencePriceValue(recurrence, { price_cents })}
                    placeholder={PLACEHOLDER_VALUES[recurrence]}
                    suffix={perRecurrenceLabels[recurrence]}
                    disabled={!value.enabled}
                    ariaLabel={`Số tiền ${perRecurrenceLabels[recurrence]}`}
                  />
                </div>
              ))}
            </fieldset>
            {allEnabledPricesAreZero ? (
              <Alert variant="info">Các cấp bậc miễn phí yêu cầu một mức giá "trả tùy ý".</Alert>
            ) : null}
            <Details
              summary={
                <Toggle
                  value={tier.customizable_price}
                  onChange={(customizable_price) => updateTier({ customizable_price })}
                  disabled={allEnabledPricesAreZero}
                >
                  Cho phép khách hàng trả tùy ý
                </Toggle>
              }
              className="toggle"
              open={tier.customizable_price}
            >
              <div className="dropdown">
                <div
                  style={{
                    display: "grid",
                    gap: "var(--spacer-3)",
                    gridTemplateColumns: "repeat(auto-fit, max(var(--dynamic-grid), 50% - var(--spacer-3) / 2))",
                  }}
                >
                  {Object.entries(tier.recurrence_price_values).flatMap(([recurrence, value]) =>
                    value.enabled ? (
                      <React.Fragment key={recurrence}>
                        <fieldset>
                          <label htmlFor={`${uid}-${recurrence}-minimum-price`}>
                            Số tiền tối thiểu {perRecurrenceLabels[recurrence]}
                          </label>
                          <PriceInput
                            id={`${uid}-${recurrence}-minimum-price`}
                            currencyCode={currencyType}
                            cents={value.price_cents}
                            disabled
                          />
                        </fieldset>
                        <fieldset>
                          <label htmlFor={`${uid}-${recurrence}-suggested-price`}>
                            Số tiền gợi ý {perRecurrenceLabels[recurrence]}
                          </label>
                          <PriceInput
                            id={`${uid}-${recurrence}-suggested-price`}
                            currencyCode={currencyType}
                            cents={value.suggested_price_cents}
                            onChange={(suggested_price_cents) =>
                              updateRecurrencePriceValue(recurrence, { suggested_price_cents })
                            }
                            placeholder={PLACEHOLDER_VALUES[recurrence]}
                          />
                        </fieldset>
                      </React.Fragment>
                    ) : (
                      []
                    ),
                  )}
                </div>
              </div>
            </Details>
            <PriceChangeSettings tier={tier} updateTier={updateTier} />
            {integrations.length > 0 ? (
              <fieldset>
                <legend>Tích hợp</legend>
                {integrations.map((integration) => (
                  <Toggle
                    value={tier.integrations[integration]}
                    onChange={(enabled) =>
                      updateTier({ integrations: { ...tier.integrations, [integration]: enabled } })
                    }
                    key={integration}
                  >
                    {integration === "circle" ? "Cho phép truy cập cộng đồng Circle" : "Cho phép truy cập máy chủ Discord"}
                  </Toggle>
                ))}
              </fieldset>
            ) : null}
          </Drawer>
        </RowDetails>
      ) : null}
    </Row>
  );
};

const getDateWithUTCOffset = (date: Date): Date => new Date(date.getTime() + date.getTimezoneOffset() * 60 * 1000);
const PriceChangeSettings = ({ tier, updateTier }: { tier: Tier; updateTier: (update: Partial<Tier>) => void }) => {
  const uid = React.useId();

  const [isMounted, setIsMounted] = React.useState(false);
  useRunOnce(() => setIsMounted(true));

  const { product, uniquePermalink, currencyType, earliestMembershipPriceChangeDate } = useProductEditContext();

  const [effectiveDate, setEffectiveDate] = React.useState<{ value: Date; error?: boolean }>({
    value: tier.subscription_price_change_effective_date
      ? new Date(tier.subscription_price_change_effective_date)
      : earliestMembershipPriceChangeDate,
  });
  effectiveDate.value = getDateWithUTCOffset(effectiveDate.value);
  React.useEffect(
    () => updateTier({ subscription_price_change_effective_date: effectiveDate.value.toISOString() }),
    [effectiveDate],
  );
  const [initialEffectiveDate] = React.useState(
    tier.subscription_price_change_effective_date
      ? getDateWithUTCOffset(new Date(tier.subscription_price_change_effective_date))
      : null,
  );

  const enabledPrice = Object.entries(tier.recurrence_price_values).find(([_, value]) => value.enabled);
  const newPrice = enabledPrice?.[1]?.enabled
    ? {
        recurrence: enabledPrice[0],
        amount: priceCentsToUnit(enabledPrice[1].price_cents ?? 0, getIsSingleUnitCurrency(currencyType)).toString(),
      }
    : { recurrence: "monthly" as const, amount: "10" };

  const [editorContent] = React.useState(tier.subscription_price_change_message);
  const [editor, setEditor] = React.useState<Editor | null>(null);

  const formattedEffectiveDate = format(effectiveDate.value, "yyyy-MM-dd");
  const placeholder = `Giá tư cách thành viên "${product.name}" của bạn sẽ thay đổi vào ngày ${formattedEffectiveDate}.

Bạn có thể sửa đổi hoặc hủy tư cách thành viên của mình bất kỳ lúc nào.`;

  React.useEffect(() => {
    if (editor) {
      editor.view.dispatch(editor.state.tr);
      const placeholderExtension = editor.extensionManager.extensions.find(({ name }) => name === "placeholder");
      if (placeholderExtension) {
        // eslint-disable-next-line @typescript-eslint/no-unsafe-member-access
        placeholderExtension.options.placeholder = placeholder;
        editor.view.dispatch(editor.state.tr);
      }
    }
  }, [placeholder, editor]);

  const onMessageChange = useDebouncedCallback((message: string) => {
    updateTier({ subscription_price_change_message: message });
  }, 500);

  return (
    <Details
      summary={
        <Toggle
          value={tier.apply_price_changes_to_existing_memberships}
          onChange={(apply_price_changes_to_existing_memberships) =>
            updateTier({
              apply_price_changes_to_existing_memberships,
              subscription_price_change_effective_date: effectiveDate.value.toISOString(),
            })
          }
        >
          Áp dụng thay đổi giá cho khách hàng hiện tại
        </Toggle>
      }
      className="toggle"
      open={tier.apply_price_changes_to_existing_memberships}
    >
      <div className="dropdown">
        <div className="grid gap-6">
          {initialEffectiveDate ? (
            <Alert variant="warning">
              Bạn đã lên lịch cập nhật giá cho khách hàng hiện tại vào ngày {format(initialEffectiveDate, "d MMMM, y")}
            </Alert>
          ) : null}
          <div>
            <strong>
              Chúng tôi sẽ gửi email nhắc nhở cho các thành viên đang hoạt động của bạn về mức giá mới 7 ngày trước kỳ
              thanh toán tiếp theo của họ.
            </strong>{" "}
            <button
              type="button"
              className="cursor-pointer underline all-unset"
              onClick={() =>
                void sendSamplePriceChangeEmail({
                  productPermalink: uniquePermalink,
                  tierId: tier.id,
                  newPrice,
                  customMessage: tier.subscription_price_change_message,
                  effectiveDate: formattedEffectiveDate,
                }).then(
                  () => {
                    showAlert("Đã gửi email mẫu! Hãy kiểm tra hộp thư của bạn", "success");
                  },
                  (e: unknown) => {
                    assertResponseError(e);
                    showAlert("Lỗi khi gửi email", "error");
                  },
                )
              }
            >
              Nhận mẫu
            </button>
          </div>
          <fieldset className={cx({ danger: effectiveDate.error })}>
            <legend>
              <label htmlFor={`${uid}-date`}>Ngày hiệu lực cho khách hàng hiện tại</label>
            </legend>
            <DateInput
              id={`${uid}-date`}
              value={effectiveDate.value}
              onChange={(value) => {
                if (!value) return;
                setEffectiveDate({ value, error: value < earliestMembershipPriceChangeDate });
              }}
            />

            {effectiveDate.error ? <small>Ngày hiệu lực phải cách ngày hôm nay ít nhất 7 ngày</small> : null}
          </fieldset>
          <fieldset>
            <legend>
              <label htmlFor={`${uid}-custom-message`}>Tin nhắn tùy chỉnh</label>
            </legend>
            {isMounted ? (
              <RichTextEditor
                id={`${uid}-custom-message`}
                className="textarea"
                placeholder={placeholder}
                ariaLabel="Tin nhắn tùy chỉnh"
                initialValue={editorContent}
                onChange={onMessageChange}
                onCreate={setEditor}
              />
            ) : null}
          </fieldset>
        </div>
      </div>
    </Details>
  );
};

export const SortableTierEditors = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement>>(
  ({ children }, ref) => (
    <Rows ref={ref} role="list" aria-label="Tier editor">
      {children}
    </Rows>
  ),
);
SortableTierEditors.displayName = "SortableTierEditors";
