import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { SettingPage } from "$app/parsers/settings";
import { asyncVoid } from "$app/utils/promise";
import { request, assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { NumberInput } from "$app/components/NumberInput";
import { showAlert } from "$app/components/server-components/Alert";
import { ToggleSettingRow } from "$app/components/SettingRow";
import { ProductLevelSupportEmailsForm } from "$app/components/Settings/AdvancedPage/ProductLevelSupportEmailsForm";
import { Layout } from "$app/components/Settings/Layout";
import { TagInput } from "$app/components/TagInput";
import { Checkbox } from "$app/components/ui/Checkbox";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { FormSection } from "$app/components/ui/FormSection";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";
import { Pill } from "$app/components/ui/Pill";
import { Select } from "$app/components/ui/Select";
import { Switch } from "$app/components/ui/Switch";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { Textarea } from "$app/components/ui/Textarea";

type ProductLevelSupportEmail = {
  email: string;
  product_ids: string[];
};

type MainPageProps = {
  settings_pages: SettingPage[];
  is_form_disabled: boolean;
  invalidate_active_sessions: boolean;
  ios_app_store_url: string;
  android_app_store_url: string;
  timezones: { name: string; offset: string }[];
  currencies: { name: string; code: string }[];
  user: {
    email: string | null;
    support_email: string | null;
    locale: string;
    timezone: string;
    currency_type: string;
    has_unconfirmed_email: boolean;
    compliance_country: string | null;
    purchasing_power_parity_enabled: boolean;
    purchasing_power_parity_limit: number | null;
    purchasing_power_parity_payment_verification_disabled: boolean;
    products: { id: string; name: string }[];
    purchasing_power_parity_excluded_product_ids: string[];
    enable_payment_email: boolean;
    enable_payment_push_notification: boolean;
    enable_recurring_subscription_charge_email: boolean;
    enable_recurring_subscription_charge_push_notification: boolean;
    enable_free_downloads_email: boolean;
    enable_free_downloads_push_notification: boolean;
    announcement_notification_enabled: boolean;
    disable_comments_email: boolean;
    disable_reviews_email: boolean;
    show_nsfw_products: boolean;
    disable_affiliate_requests: boolean;
    seller_refund_policy: {
      enabled: boolean;
      allowed_refund_periods_in_days: { key: number; value: string }[];
      max_refund_period_in_days: number;
      fine_print_enabled: boolean;
      fine_print: string | null;
    };
    product_level_support_emails: ProductLevelSupportEmail[] | null;
  };
};

export default function MainPage() {
  const props = cast<MainPageProps>(usePage().props);
  const uid = React.useId();

  const form = useForm({
    user: {
      ...props.user,
      email: props.user.email ?? "",
      support_email: props.user.support_email ?? "",
      tax_id: null,
      purchasing_power_parity_excluded_product_ids: props.user.purchasing_power_parity_excluded_product_ids,
      product_level_support_emails: props.user.product_level_support_emails ?? [],
    },
  });

  const isFormDisabled = props.is_form_disabled || form.processing;

  const updateUserSettings = (settings: Partial<typeof form.data.user>) =>
    form.setData("user", { ...form.data.user, ...settings });
  const handleProductLevelSupportEmailsChange = (emails: ProductLevelSupportEmail[]) =>
    updateUserSettings({ product_level_support_emails: emails });

  const [resentConfirmationEmail, setResentConfirmationEmail] = React.useState(false);
  const formRef = React.useRef<HTMLFormElement>(null);

  const resendConfirmationEmailForm = useForm({});

  const resendConfirmationEmail = () => {
    resendConfirmationEmailForm.post(Routes.resend_confirmation_email_settings_main_path(), {
      onSuccess: () => {
        setResentConfirmationEmail(true);
      },
    });
  };

  const onSave = () => {
    if (props.is_form_disabled) return;
    if (!formRef.current?.reportValidity()) return;

    form.put(Routes.settings_main_path(), {
      preserveScroll: true,
    });
  };

  return (
    <Layout currentPage="main" pages={props.settings_pages} onSave={onSave} canUpdate={!isFormDisabled}>
      <form ref={formRef}>
        <FormSection header={<h2>User details</h2>}>
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-email`}>Email</Label>
            </FieldsetTitle>
            <Input
              type="email"
              id={`${uid}-email`}
              value={form.data.user.email}
              disabled={isFormDisabled}
              required
              onChange={(e) => updateUserSettings({ email: e.target.value })}
            />
            {props.user.has_unconfirmed_email && !props.is_form_disabled ? (
              <FieldsetDescription>
                This email address has not been confirmed yet.{" "}
                {resentConfirmationEmail ? null : (
                  <button
                    className="cursor-pointer underline all-unset"
                    onClick={(e) => {
                      e.preventDefault();
                      resendConfirmationEmail();
                    }}
                  >
                    {resendConfirmationEmailForm.processing ? "Resending..." : "Resend confirmation?"}
                  </button>
                )}
              </FieldsetDescription>
            ) : null}
          </Fieldset>
        </FormSection>
        <FormSection
          header={
            <>
              <h2>Notifications</h2>
              <div>
                Depending on your preferences, you can choose whether to receive mobile notifications or email
                notifications. If you want to get notifications on a mobile device, install the Gumroad app over on the{" "}
                <a href={props.ios_app_store_url} target="_blank" rel="noopener noreferrer">
                  App Store
                </a>{" "}
                or{" "}
                <a href={props.android_app_store_url} target="_blank" rel="noopener noreferrer">
                  Play Store
                </a>
                .
              </div>
            </>
          }
        >
          <Fieldset>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Notifications</TableHead>
                  <TableHead>Email</TableHead>
                  <TableHead>Mobile</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                <TableRow>
                  <TableHead scope="row">Purchases</TableHead>
                  <TableCell>
                    <Switch
                      checked={form.data.user.enable_payment_email}
                      onChange={(e) => updateUserSettings({ enable_payment_email: e.target.checked })}
                      disabled={isFormDisabled}
                    />
                  </TableCell>
                  <TableCell>
                    <Switch
                      checked={form.data.user.enable_payment_push_notification}
                      onChange={(e) => updateUserSettings({ enable_payment_push_notification: e.target.checked })}
                      disabled={isFormDisabled}
                    />
                  </TableCell>
                </TableRow>
                <TableRow>
                  <TableHead scope="row">Recurring payments</TableHead>
                  <TableCell>
                    <Switch
                      checked={form.data.user.enable_recurring_subscription_charge_email}
                      onChange={(e) =>
                        updateUserSettings({ enable_recurring_subscription_charge_email: e.target.checked })
                      }
                      disabled={isFormDisabled}
                    />
                  </TableCell>
                  <TableCell>
                    <Switch
                      checked={form.data.user.enable_recurring_subscription_charge_push_notification}
                      onChange={(e) =>
                        updateUserSettings({
                          enable_recurring_subscription_charge_push_notification: e.target.checked,
                        })
                      }
                      disabled={isFormDisabled}
                    />
                  </TableCell>
                </TableRow>
                <TableRow>
                  <TableHead scope="row">Free downloads</TableHead>
                  <TableCell>
                    <Switch
                      checked={form.data.user.enable_free_downloads_email}
                      onChange={(e) => updateUserSettings({ enable_free_downloads_email: e.target.checked })}
                      disabled={isFormDisabled}
                    />
                  </TableCell>
                  <TableCell>
                    <Switch
                      checked={form.data.user.enable_free_downloads_push_notification}
                      onChange={(e) =>
                        updateUserSettings({ enable_free_downloads_push_notification: e.target.checked })
                      }
                      disabled={isFormDisabled}
                    />
                  </TableCell>
                </TableRow>
                <TableRow>
                  <TableHead scope="row">Personalized product announcements</TableHead>
                  <TableCell>
                    <Switch
                      checked={form.data.user.announcement_notification_enabled}
                      onChange={(e) => updateUserSettings({ announcement_notification_enabled: e.target.checked })}
                      disabled={isFormDisabled}
                    />
                  </TableCell>
                  <TableCell></TableCell>
                </TableRow>
                <TableRow>
                  <TableHead scope="row">Comments</TableHead>
                  <TableCell>
                    <Switch
                      checked={!form.data.user.disable_comments_email}
                      onChange={(e) => updateUserSettings({ disable_comments_email: !e.target.checked })}
                      disabled={isFormDisabled}
                    />
                  </TableCell>
                  <TableCell></TableCell>
                </TableRow>
                <TableRow>
                  <TableHead scope="row">Reviews</TableHead>
                  <TableCell>
                    <Switch
                      checked={!form.data.user.disable_reviews_email}
                      onChange={(e) => updateUserSettings({ disable_reviews_email: !e.target.checked })}
                      disabled={isFormDisabled}
                      aria-label="Reviews"
                    />
                  </TableCell>
                  <TableCell></TableCell>
                </TableRow>
              </TableBody>
            </Table>
          </Fieldset>
        </FormSection>
        <FormSection header={<h2>Support</h2>}>
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-support-email`}>Email</Label>
            </FieldsetTitle>
            <Input
              type="email"
              id={`${uid}-support-email`}
              value={form.data.user.support_email}
              placeholder={props.user.email ?? ""}
              disabled={isFormDisabled}
              onChange={(e) => updateUserSettings({ support_email: e.target.value })}
            />
            <FieldsetDescription>This email is listed on the receipt of every sale.</FieldsetDescription>
          </Fieldset>
          {props.user.product_level_support_emails !== null && (
            <ProductLevelSupportEmailsForm
              productLevelSupportEmails={form.data.user.product_level_support_emails}
              products={props.user.products}
              isDisabled={isFormDisabled}
              onChange={handleProductLevelSupportEmailsChange}
            />
          )}
        </FormSection>
        {props.user.seller_refund_policy.enabled ? (
          <FormSection
            header={
              <>
                <h2>Refund policy</h2>
                <div>Choose how refunds will be handled for your products.</div>
              </>
            }
          >
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor="max-refund-period-in-days">Refund period</Label>
              </FieldsetTitle>
              <Select
                id="max-refund-period-in-days"
                value={form.data.user.seller_refund_policy.max_refund_period_in_days}
                disabled={isFormDisabled}
                onChange={(e) =>
                  updateUserSettings({
                    seller_refund_policy: {
                      ...form.data.user.seller_refund_policy,
                      max_refund_period_in_days: Number(e.target.value),
                    },
                  })
                }
              >
                {form.data.user.seller_refund_policy.allowed_refund_periods_in_days.map(({ key, value }) => (
                  <option key={key} value={key}>
                    {value}
                  </option>
                ))}
              </Select>
            </Fieldset>
            <Fieldset>
              <ToggleSettingRow
                value={
                  form.data.user.seller_refund_policy.fine_print_enabled
                    ? form.data.user.seller_refund_policy.max_refund_period_in_days > 0
                    : false
                }
                onChange={(value) =>
                  updateUserSettings({
                    seller_refund_policy: {
                      ...form.data.user.seller_refund_policy,
                      fine_print_enabled: value,
                    },
                  })
                }
                disabled={isFormDisabled || form.data.user.seller_refund_policy.max_refund_period_in_days === 0}
                label="Add a fine print to your refund policy"
                dropdown={
                  <Fieldset>
                    <FieldsetTitle>
                      <Label htmlFor="seller-refund-policy-fine-print">Fine print</Label>
                    </FieldsetTitle>
                    <Textarea
                      id="seller-refund-policy-fine-print"
                      maxLength={3000}
                      rows={10}
                      value={form.data.user.seller_refund_policy.fine_print || ""}
                      placeholder="Describe your refund policy"
                      disabled={isFormDisabled}
                      onChange={(e) =>
                        updateUserSettings({
                          seller_refund_policy: {
                            ...form.data.user.seller_refund_policy,
                            fine_print: e.target.value,
                          },
                        })
                      }
                    />
                  </Fieldset>
                }
              />
            </Fieldset>
          </FormSection>
        ) : null}
        <FormSection header={<h2>Local</h2>}>
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-timezone`}>Time zone</Label>
            </FieldsetTitle>
            <Select
              id={`${uid}-timezone`}
              disabled={isFormDisabled}
              value={form.data.user.timezone}
              onChange={(e) => updateUserSettings({ timezone: e.target.value })}
            >
              {props.timezones.map((tz) => (
                <option key={tz.name} value={tz.name}>
                  {`${tz.offset} | ${tz.name}`}
                </option>
              ))}
            </Select>
          </Fieldset>
          <Fieldset>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-local-currency`}>Sell in...</Label>
            </FieldsetTitle>
            <Select
              id={`${uid}-local-currency`}
              disabled={isFormDisabled}
              value={form.data.user.currency_type}
              onChange={(e) => updateUserSettings({ currency_type: e.target.value })}
            >
              {props.currencies.map((currency) => (
                <option key={currency.code} value={currency.code}>
                  {currency.name}
                </option>
              ))}
            </Select>
            <FieldsetDescription>Applies only to new products.</FieldsetDescription>
            <FieldsetDescription>
              Charges will happen in USD, using an up-to-date exchange rate. Customers may incur an additional foreign
              transaction fee according to their cardmember agreement.
            </FieldsetDescription>
          </Fieldset>
          <Fieldset>
            <ToggleSettingRow
              value={form.data.user.purchasing_power_parity_enabled}
              onChange={(value) => updateUserSettings({ purchasing_power_parity_enabled: value })}
              disabled={isFormDisabled}
              label="Enable purchasing power parity"
              dropdown={
                <div className="flex flex-col gap-4">
                  <Fieldset>
                    <FieldsetTitle>
                      <Label htmlFor={`${uid}-ppp-discount-percentage`}>Maximum PPP discount</Label>
                    </FieldsetTitle>
                    <InputGroup disabled={props.is_form_disabled}>
                      <NumberInput
                        value={form.data.user.purchasing_power_parity_limit}
                        onChange={(value) => {
                          if (value === null || (value > 0 && value <= 100)) {
                            updateUserSettings({ purchasing_power_parity_limit: value });
                          }
                        }}
                      >
                        {(inputProps) => (
                          <Input
                            id={`${uid}-ppp-discount-percentage`}
                            type="text"
                            placeholder="60"
                            disabled={isFormDisabled}
                            aria-label="Percentage"
                            {...inputProps}
                          />
                        )}
                      </NumberInput>
                      <Pill className="-mr-2 shrink-0">%</Pill>
                    </InputGroup>
                  </Fieldset>
                  <Switch
                    checked={!form.data.user.purchasing_power_parity_payment_verification_disabled}
                    disabled={isFormDisabled}
                    onChange={(e) =>
                      updateUserSettings({ purchasing_power_parity_payment_verification_disabled: !e.target.checked })
                    }
                    label="Apply only if the customer is currently located in the country of their payment method"
                  />
                  <Fieldset>
                    <FieldsetTitle>
                      <Label htmlFor={`${uid}-ppp-exclude-products`}>Products to exclude</Label>
                    </FieldsetTitle>

                    <TagInput
                      inputId={`${uid}-ppp-exclude-products`}
                      tagIds={form.data.user.purchasing_power_parity_excluded_product_ids}
                      tagList={props.user.products.map(({ id, name }) => ({ id, label: name }))}
                      isDisabled={isFormDisabled}
                      onChangeTagIds={(productIds) =>
                        updateUserSettings({ purchasing_power_parity_excluded_product_ids: productIds })
                      }
                    />

                    <Label>
                      <Checkbox
                        disabled={isFormDisabled}
                        checked={
                          form.data.user.purchasing_power_parity_excluded_product_ids.length ===
                          props.user.products.length
                        }
                        onChange={(evt) =>
                          updateUserSettings({
                            purchasing_power_parity_excluded_product_ids: evt.target.checked
                              ? props.user.products.map(({ id }) => id)
                              : [],
                          })
                        }
                      />
                      All products
                    </Label>
                  </Fieldset>
                </div>
              }
            />
            <FieldsetDescription>
              Charge customers different amounts depending on the cost of living in their country.{" "}
              <a href="/help/article/327-purchasing-power-parity" target="_blank" rel="noreferrer">
                Learn more
              </a>
            </FieldsetDescription>
          </Fieldset>
        </FormSection>
        <FormSection header={<h2>Adult content</h2>}>
          <Fieldset>
            <ToggleSettingRow
              value={form.data.user.show_nsfw_products}
              onChange={(value) => updateUserSettings({ show_nsfw_products: value })}
              disabled={isFormDisabled}
              label="Show adult content in recommendations and search results"
            />
          </Fieldset>
        </FormSection>
        <FormSection header={<h2>Affiliates</h2>}>
          <Fieldset>
            <ToggleSettingRow
              value={form.data.user.disable_affiliate_requests}
              onChange={(value) => updateUserSettings({ disable_affiliate_requests: value })}
              disabled={isFormDisabled}
              label="Prevent others from adding me as an affiliate"
            />
            <FieldsetDescription>
              When enabled, other users cannot add you as an affiliate or request to become your affiliate.
            </FieldsetDescription>
          </Fieldset>
        </FormSection>
        {props.invalidate_active_sessions ? <InvalidateActiveSessionsSection /> : null}
      </form>
    </Layout>
  );
}

const InvalidateActiveSessionsSection = () => {
  const [isConfirmationDialogOpen, setIsConfirmationDialogOpen] = React.useState(false);
  const [isInvalidating, setIsInvalidating] = React.useState(false);

  const invalidateActiveSessions = asyncVoid(async () => {
    setIsInvalidating(true);

    try {
      await request({ url: Routes.user_invalidate_active_sessions_path(), method: "PUT", accept: "json" });

      location.reload();
    } catch (e) {
      assertResponseError(e);
      showAlert("Sorry, something went wrong. Please try again.", "error");
    }

    setIsConfirmationDialogOpen(false);
    setIsInvalidating(false);
  });

  return (
    <FormSection>
      <Fieldset>
        <button
          className="cursor-pointer underline all-unset"
          type="button"
          onClick={() => setIsConfirmationDialogOpen(true)}
        >
          Sign out from all active sessions
        </button>
        <small>You will be signed out from all your active sessions including this session.</small>
      </Fieldset>
      {isConfirmationDialogOpen ? (
        <Modal
          open
          title="Sign out from all active sessions"
          onClose={() => !isInvalidating && setIsConfirmationDialogOpen(false)}
          footer={
            <>
              <Button onClick={() => setIsConfirmationDialogOpen(false)} disabled={isInvalidating}>
                Cancel
              </Button>
              <Button color="accent" onClick={() => invalidateActiveSessions()} disabled={isInvalidating}>
                {isInvalidating ? "Signing out from all active sessions..." : "Yes, sign out"}
              </Button>
            </>
          }
        >
          Are you sure that you would like to sign out from all active sessions? You will be signed out from this
          session as well.
        </Modal>
      ) : null}
    </FormSection>
  );
};
