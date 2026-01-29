import { usePage } from "@inertiajs/react";
import React, { useEffect, useState } from "react";

export default function Alert() {
  const { flash } = usePage<{ flash: { success?: string; alert?: string; error?: string } }>().props;
  const [isVisible, setIsVisible] = useState(false);

  const message = flash.success || flash.alert || flash.error;
  const type = flash.success ? "success" : "error";

  useEffect(() => {
    if (message) {
      setIsVisible(true);
      const timer = setTimeout(() => setIsVisible(false), 5000);
      return () => clearTimeout(timer);
    }
  }, [message]);

  if (!isVisible || !message) return null;

  return (
    <div className={`fixed top-4 right-4 p-4 rounded shadow-lg text-white ${type === "success" ? "bg-green-500" : "bg-red-500"}`} style={{ zIndex: 9999 }}>
      {message}
      <button onClick={() => setIsVisible(false)} className="ml-4 font-bold">×</button>
    </div>
  );
}
