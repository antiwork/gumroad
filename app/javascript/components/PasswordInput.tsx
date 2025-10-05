import * as React from "react";

type PasswordInputProps = Omit<React.ComponentPropsWithoutRef<"input">, "type"> & {
  value: string;
  onChange: (e: React.ChangeEvent<HTMLInputElement>) => void;
};

const EyeIcon = (props: React.ComponentPropsWithoutRef<"span">) => (
  <span {...props}>
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" fill="none">
      <path
        stroke="currentColor"
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth="2"
        d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0"
      />
      <path
        stroke="currentColor"
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth="2"
        d="M12.001 5C7.524 5 3.733 7.943 2.46 12c1.274 4.057 5.065 7 9.542 7 4.478 0 8.268-2.943 9.542-7-1.274-4.057-5.064-7-9.542-7"
      />
    </svg>
  </span>
);

const EyeSlashIcon = (props: React.ComponentPropsWithoutRef<"span">) => (
  <span {...props}>
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" fill="none">
      <path
        stroke="currentColor"
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth="2"
        d="m2.999 3 18 18M9.843 9.914a3 3 0 0 0 4.265 4.22M6.5 6.646A10.02 10.02 0 0 0 2.457 12c1.274 4.057 5.065 7 9.542 7 1.99 0 3.842-.58 5.4-1.582m-6.4-12.369q.494-.049 1-.049c4.478 0 8.268 2.943 9.542 7a10 10 0 0 1-1.189 2.5"
      />
    </svg>
  </span>
);

export const PasswordInput = React.forwardRef<HTMLInputElement, PasswordInputProps>(({ className, ...props }, ref) => {
  const [showPassword, setShowPassword] = React.useState(false);

  const togglePasswordVisibility = () => {
    setShowPassword(!showPassword);
  };

  const IconComponent = showPassword ? EyeSlashIcon : EyeIcon;

  return (
    <div className="input">
      <input ref={ref} type={showPassword ? "text" : "password"} className={className} {...props} />
      <IconComponent
        onClick={togglePasswordVisibility}
        role="button"
        tabIndex={0}
        className="cursor-pointer select-none"
        aria-label={showPassword ? "Hide password" : "Show password"}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            togglePasswordVisibility();
          }
        }}
      />
    </div>
  );
});

PasswordInput.displayName = "PasswordInput";
