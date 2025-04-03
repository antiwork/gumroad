const Mobile = {
  isOnMobileiOSDevice(): boolean {
    return /iPad|iPhone|iPod/u.test(navigator.userAgent) && !document.cookie.includes("iphone_redirect=false");
  },
  isOnAndroidDevice(): boolean {
    return /Android/iu.exec(navigator.userAgent) != null;
  },
  isOnTouchDevice(): boolean {
    // https://stackoverflow.com/a/52855084/1850609
    return window.matchMedia("(pointer: coarse)").matches;
  },
};
export default Mobile;
