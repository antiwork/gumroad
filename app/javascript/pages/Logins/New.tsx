import { Link, useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { AuthAlert } from "$app/components/AuthAlert";
import { Layout } from "$app/components/Authentication/Layout";
import { SocialAuth } from "$app/components/Authentication/SocialAuth";
import { Button } from "$app/components/Button";
import { PasswordInput } from "$app/components/PasswordInput";
import { Separator } from "$app/components/Separator";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { RecaptchaCancelledError, useRecaptcha } from "$app/components/useRecaptcha";

type PageProps = {
  email: string | null;
  application_name: string | null;
  recaptcha_site_key: string | null;
  authenticity_token: string;
};

type FormData = {
  user: {
    login_identifier: string;
    password: string;
  };
  next: string | null;
  "g-recaptcha-response": string | null;
  authenticity_token: string;
};

function LoginPage() {
  const { email: initialEmail, application_name, recaptcha_site_key, authenticity_token } = usePage<PageProps>().props;

  const url = new URL(useOriginalLocation());
  const next = url.searchParams.get("next");
  const recaptcha = useRecaptcha({ siteKey: recaptcha_site_key });
  const uid = React.useId();

  const form = useForm<FormData>({
    user: {
      login_identifier: initialEmail ?? "",
      password: "",
    },
    next,
    "g-recaptcha-response": null,
    authenticity_token,
  });

  const handleSubmit = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    try {
      const recaptchaResponse = recaptcha_site_key !== null ? await recaptcha.execute() : null;
      form.transform((data) => ({
        ...data,
        "g-recaptcha-response": recaptchaResponse,
      }));
      form.post(Routes.login_path());
    } catch (e) {
      if (e instanceof RecaptchaCancelledError) return;
      throw e;
    }
  };

  return (
    <Layout header={application_name ? `Đăng nhập ${application_name}` : "Đăng nhập"}>
      <form className="space-y-6" onSubmit={(e) => void handleSubmit(e)}>
        <AuthAlert />
        <fieldset>
          <legend>
            <label htmlFor={`${uid}-email`}>Email</label>
          </legend>
          <div className="relative group input-focus border border-slate-200 rounded-2xl bg-slate-50 transition-all overflow-hidden">
            <input
              id={`${uid}-email`}
              type="email"
              value={form.data.user.login_identifier}
              onChange={(e) => form.setData("user.login_identifier", e.target.value)}
              required
              tabIndex={1}
              autoComplete="email"
              className="w-full bg-transparent text-slate-900 text-sm p-4 pl-12 outline-none border-none appearance-none focus:ring-0 focus:outline-none"
            />
          </div>
        </fieldset>
        <fieldset>
          <legend>
            <label htmlFor={`${uid}-password`}>Mật khẩu</label>
            <Link href={Routes.new_user_password_path({ next })} className="font-normal underline">
              Quên mật khẩu?
            </Link>
          </legend>
          <div className="relative group input-focus border border-slate-200 rounded-2xl bg-slate-50 transition-all overflow-hidden">
            <PasswordInput
              id={`${uid}-password`}
              value={form.data.user.password}
              onChange={(e) => form.setData("user.password", e.target.value)}
              required
              tabIndex={1}
              autoComplete="current-password"
            />
          </div>
        </fieldset>
        <Button color="primary" type="submit" disabled={form.processing} className="w-full ">
          {form.processing ? "Đang đăng nhập..." : "Đăng nhập"}
        </Button>
        <Separator>
          <span>Tùy chọn khác</span>
        </Separator>
        <SocialAuth />

        <p className="mt-10 text-center text-sm text-slate-500 font-medium">
          Thành viên mới?
          <Link
            href={Routes.signup_path({ next })}
            className="ms-1 font-extrabold text-blue-600 hover:text-blue-700 hover:underline underline-offset-4">
            Tạo tài khoản
          </Link>
        </p>
      </form>
      {recaptcha.container}
    </Layout>
  );
}

LoginPage.disableLayout = true;
export default LoginPage;
