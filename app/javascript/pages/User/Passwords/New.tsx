import { Link, useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { AuthAlert } from "$app/components/AuthAlert";
import { Layout } from "$app/components/Authentication/Layout";
import { SocialAuth } from "$app/components/Authentication/SocialAuth";
import { Button } from "$app/components/Button";
import { Separator } from "$app/components/Separator";
import { useOriginalLocation } from "$app/components/useOriginalLocation";

type PageProps = {
  email: string | null;
  application_name: string | null;
};

function ForgotPasswordPage() {
  const { email: initialEmail, application_name } = usePage<PageProps>().props;
  const uid = React.useId();

  const url = new URL(useOriginalLocation());
  const next = url.searchParams.get("next") || "dashboard";

  const form = useForm({
    user: {
      email: initialEmail ?? "",
    },
  });

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    form.post(Routes.user_password_path());
  };

  return (
    <Layout header={application_name ? `Kết nối ${application_name} với Gumroad` : "Quên mật khẩu"}>
      <form className="space-y-6" onSubmit={handleSubmit}>
        <AuthAlert />
        <fieldset>
          <legend>
            <label htmlFor={uid}>Email để gửi hướng dẫn đặt lại mật khẩu</label>
          </legend>
          <div className="relative group input-focus border border-slate-200 rounded-2xl bg-slate-50 transition-all overflow-hidden">
            <input
              id={uid}
              type="email"
              value={form.data.user.email}
              onChange={(e) => form.setData("user.email", e.target.value)}
              required
              autoFocus
              autoComplete="email"
            />
          </div>
        </fieldset>
        <Button color="primary" type="submit" className="w-full" disabled={form.processing}>
          {form.processing ? "Đang gửi..." : "Gửi"}
        </Button>
        <Separator>
          <span>Tùy chọn khác</span>
        </Separator>
        <SocialAuth />

        <p className="mt-10 text-center text-sm text-slate-500 font-medium">
          Bạn đã có tài khoản?
          <Link
            href={Routes.login_path({ next })}
            className="ms-1 font-extrabold text-blue-600 hover:text-blue-700 hover:underline underline-offset-4">
            Đăng nhập
          </Link>
        </p>
      </form>
    </Layout>
  );
}

ForgotPasswordPage.disableLayout = true;
export default ForgotPasswordPage;
