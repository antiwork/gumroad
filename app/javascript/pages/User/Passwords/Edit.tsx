import { Link, useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { AuthAlert } from "$app/components/AuthAlert";
import { Layout } from "$app/components/Authentication/Layout";
import { Button } from "$app/components/Button";
import { PasswordInput } from "$app/components/PasswordInput";

type PageProps = {
  reset_password_token: string;
};

function PasswordReset() {
  const { reset_password_token } = usePage<PageProps>().props;
  const uid = React.useId();

  const form = useForm({
    user: {
      password: "",
      password_confirmation: "",
      reset_password_token,
    },
  });

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    form.put(Routes.user_password_path());
  };

  return (
    <Layout header="Đặt lại mật khẩu">
      <form className="space-y-4" onSubmit={handleSubmit}>
        <AuthAlert />
        <fieldset>
          <legend>
            <label htmlFor={`${uid}-password`}>Nhập mật khẩu mới</label>
          </legend>
          <div className="relative group input-focus border border-slate-200 rounded-2xl bg-slate-50 transition-all overflow-hidden">
            <PasswordInput
              id={`${uid}-password`}
              value={form.data.user.password}
              onChange={(e) => form.setData("user.password", e.target.value)}
              placeholder="Password"
              required
              autoFocus
              autoComplete="new-password"
            />
          </div>
        </fieldset>
        <fieldset>
          <legend>
            <label htmlFor={`${uid}-password-confirmation`}>Xác nhận mật khẩu</label>
          </legend>
          <div className="relative group input-focus border border-slate-200 rounded-2xl bg-slate-50 transition-all overflow-hidden">
            <PasswordInput
              id={`${uid}-password-confirmation`}
              value={form.data.user.password_confirmation}
              onChange={(e) => form.setData("user.password_confirmation", e.target.value)}
              placeholder="Xác nhận mật khẩu"
              required
              autoComplete="new-password"
            />
          </div>
        </fieldset>
        <Button color="primary" type="submit" disabled={form.processing}>
          {form.processing ? "Đang đặt lại..." : "Đặt lại mật khẩu"}
        </Button>
        <p className="mt-10 text-center text-sm text-slate-500 font-medium">
          Đã có tài khoản?
          <Link href={Routes.login_path()} className="ms-1 font-extrabold text-blue-600 hover:text-blue-700 hover:underline underline-offset-4">Đăng nhập</Link>
        </p>
      </form>
    </Layout>
  );
}

PasswordReset.disableLayout = true;
export default PasswordReset;
