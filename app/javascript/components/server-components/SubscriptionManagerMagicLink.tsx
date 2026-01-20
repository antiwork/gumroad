import * as React from "react";
import { createCast } from "ts-safe-cast";

import { sendMagicLink } from "$app/data/subscription_magic_link";
import { assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Layout } from "$app/components/Authentication/Layout";
import { Button } from "$app/components/Button";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { showAlert } from "$app/components/server-components/Alert";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

type UserEmail = { email: string; source: string };

type SubscriptionManagerMagicLinkProps = {
  product_name: string;
  subscription_id: string;
  is_installment_plan: boolean;
  user_emails: [UserEmail, ...UserEmail[]];
};
const SubscriptionManagerMagicLink = ({
  product_name,
  subscription_id,
  is_installment_plan,
  user_emails,
}: SubscriptionManagerMagicLinkProps) => {
  const [loading, setLoading] = React.useState(false);
  const [hasSentEmail, setHasSentEmail] = React.useState(false);
  const [selectedUserEmail, setSelectedUserEmail] = React.useState(user_emails[0]);

  const subscriptionEntity = is_installment_plan ? "installment plan" : "membership";
  const invalid = new URL(useOriginalLocation()).searchParams.get("invalid") === "true";

  const handleSendMagicLink = async () => {
    setLoading(true);
    try {
      await sendMagicLink({ emailSource: selectedUserEmail.source, subscriptionId: subscription_id });
      if (hasSentEmail) {
        showAlert(`Magic link resent to ${selectedUserEmail.email}.`, "success");
      }
      setHasSentEmail(true);
    } catch (error) {
      assertResponseError(error);
      showAlert(error.message, "error");
    }
    setLoading(false);
  };

  const title = hasSentEmail
    ? `Chúng tôi đã gửi link đến ${selectedUserEmail.email}.`
    : invalid
      ? "Liên kết của bạn đã hết hạn."
      : "Bạn chưa đăng nhập.";
  const subtitle = hasSentEmail
    ? `Vui lòng kiểm tra hộp thư đến và nhấp vào liên kết trong email để quản lý ${subscriptionEntity}.`
    : user_emails.length > 1
      ? `Để quản lý ${subscriptionEntity} cho ${product_name}, hãy chọn một trong các email được liên kết với tài khoản của bạn để nhận liên kết.`
      : `Để quản lý ${subscriptionEntity} cho ${product_name}, hãy nhấp vào nút bên dưới để nhận liên kết tại ${selectedUserEmail.email}`;

  return (
    <Layout
      header={
        <>
          <h1 className="mt-12">{title}</h1>
          <h3>{subtitle}</h3>
        </>
      }
      headerActions={<a href={Routes.login_path()}>Đăng nhập</a>}
    >
      <form className="space-y-6">
        {hasSentEmail ? (
          <>
            <Button color="primary" className="w-full" onClick={() => void handleSendMagicLink()} disabled={loading}>
              {loading ? <LoadingSpinner /> : null}
              Gửi lại link
            </Button>
            <p>
              {user_emails.length > 1 ? (
                <>
                  Không thấy email? Vui lòng kiểm tra thư mục spam.{" "}
                  <button className="cursor-pointer underline all-unset" onClick={() => setHasSentEmail(false)}>
                    Chọn email khác
                  </button>{" "}
                  hoặc thử gửi lại link ở trên.
                </>
              ) : (
                "Không thấy email? Vui lòng kiểm tra thư mục spam hoặc thử gửi lại link ở trên."
              )}
            </p>
          </>
        ) : (
          <>
            {user_emails.length > 1 ? (
              <fieldset>
                <legend>Chọn email</legend>
                {user_emails.map((userEmail) => (
                  <label key={userEmail.source}>
                    <input
                      type="radio"
                      name="email_source"
                      value={userEmail.source}
                      onChange={() => setSelectedUserEmail(userEmail)}
                      checked={userEmail === selectedUserEmail}
                    />
                    {userEmail.email}
                  </label>
                ))}
              </fieldset>
            ) : null}
            <Button color="primary" onClick={() => void handleSendMagicLink()} disabled={loading}>
              {loading ? <LoadingSpinner /> : null}
              Gửi link
            </Button>
          </>
        )}
      </form>
    </Layout>
  );
};

export default register({ component: SubscriptionManagerMagicLink, propParser: createCast() });
