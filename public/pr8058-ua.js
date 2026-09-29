document.getElementById("h").textContent = location.host;
document.getElementById("s").textContent = String(window.isSecureContext);
document.getElementById("u").textContent = navigator.userAgent;
var m = document.cookie.match(/_gumroad_guid=([^;]+)/);
document.getElementById("c").textContent = m ? "present" : "absent";
