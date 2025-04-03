const deserializeData = (serData: string): unknown => JSON.parse(decodeURIComponent(serData));

export const readCookie = function (name: string): unknown {
  const cookieSet = document.cookie.split(";");
  for (const cookiePair of cookieSet) {
    const cookie = cookiePair.split("=");
    const key = cookie[0].trim();
    const value = cookie[1];
    if (key === name && typeof value !== "undefined") {
      try {
        return deserializeData(value);
      } catch {
        writeCookie(name, ""); // erase unreadable cookie
      }
    }
  }
  return false;
};

const serializeData = (data: unknown): string => encodeURIComponent(JSON.stringify(data));

export const writeCookie = function (name: string, data: unknown) {
  if (process.env.NODE_ENV !== "production") {
    document.cookie = `${name}=${serializeData(data)}; SameSite=Lax; path=/`;
  } else {
    document.cookie = `${name}=${serializeData(data)}; SameSite=None; Secure; path=/`;
  }
};
