import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { AuthAlert } from "$app/components/AuthAlert";
import { Layout } from "$app/components/Authentication/Layout";
import { Button } from "$app/components/Button";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

type PageProps = {
  user_id: string;
  email: string;
  token: string | null;
  authenticity_token: string;
};

type FormData = {
  token: string;
  next: string | null;
  authenticity_token: string;
};

function TwoFactorAuthentication() {
  const { user_id, email, token: initialToken, authenticity_token } = usePage<PageProps>().props;
  const next = new URL(useOriginalLocation()).searchParams.get("next");
  const uid = React.useId();

  const form = useForm<FormData>({
    token: initialToken ?? "",
    next,
    authenticity_token,
  });

  const resendForm = useForm({ authenticity_token });

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    form.post(Routes.two_factor_authentication_path({ user_id }));
  };

  const resendToken = () => {
    resendForm.post(Routes.resend_authentication_token_path({ user_id }));
  };

  return (
    <Layout
      header={
        <>
          <h1>Xác thực hai yếu tố</h1>
          <h3>
            Để bảo vệ tài khoản của bạn, chúng tôi đã gửi một Mã xác thực đến {email}. Vui lòng nhập mã vào đây để tiếp tục.
          </h3>
        </>
      }
    >
      <form className="space-y-4" onSubmit={handleSubmit}>
        <AuthAlert />
        <fieldset>
          <legend>
            <label htmlFor={uid}>Mã xác thực</label>
          </legend>
          <div className="relative group input-focus border border-slate-200 rounded-2xl bg-slate-50 transition-all overflow-hidden">
            <input
              id={uid}
              type="text"
              value={form.data.token}
              onChange={(e) => form.setData("token", e.target.value)}
              required
              autoFocus
            />
          </div>
        </fieldset>
        <Button color="primary" type="submit" disabled={form.processing}>
          {form.processing ? "Đang xác thực..." : "Xác thực"}
        </Button>
        <Button disabled={resendForm.processing} onClick={() => resendToken()}>
          Gửi lại mã xác thực
        </Button>
      </form>
    </Layout>
  );
}

TwoFactorAuthentication.disableLayout = true;
export default TwoFactorAuthentication;
